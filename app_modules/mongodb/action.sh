#!/usr/bin/env bash

if [[ "init status dbs create-db create-admin delete-user users change-password" == *"$1"* ]]; then
  CMD="$1"
else
  exit 0
fi

for i in "$@"; do
  case $i in
    --database=*)
    DATABASE="${i#*=}"
    shift
    ;;
    --username=*)
    USERNAME="${i#*=}"
    shift
    ;;
    --verbose)
    VERBOSE=true
    shift
    ;;
    --force)
    FORCE=true
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

if [ "$CMD" = "init" ]; then
  echo "Initializing MongoDB replica set"
  podman exec mongodb-4 mongo --port 27017 --eval "rs.initiate({_id: \"rs0\", members: [{_id: 0, host: \"$NODE_1\", priority: 100},{_id: 1, host: \"$NODE_2\"},{_id: 2, host: \"$NODE_3\"}]})"
  echo "Result Code: $?"
fi

if [ "$CMD" = "status" ]; then
  podman exec mongodb-4 mongo --quiet --port 27017 --eval 'rs.status()'
  echo "Result Code: $?"
fi

if [ "$CMD" = "dbs" ]; then
  echo "dbs..."
  if [ -z "$VERBOSE" ]; then
    podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
      db = db.getSiblingDB('admin');
      let result = db.adminCommand('listDatabases');
      result.databases.forEach(function(db) {
        print(db.name);
      });
EOF
    )"
  else
    podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
      db = db.getSiblingDB('admin');
      let result = db.adminCommand('listDatabases');
      print('\nDatabase List:');
      print('=============');
      result.databases.forEach(function(db) {
        let size = (db.sizeOnDisk / 1024 / 1024).toFixed(2);
        print(db.name + ' (' + size + ' MB)');
      });
      print('\nTotal size: ' + (result.totalSize / 1024 / 1024).toFixed(2) + ' MB');
      print('Total number of databases: ' + result.databases.length);
EOF
    )"
  fi
fi

# The action command is currently not interactive
# if [ "$CMD" = "shell" ]; then
#   podman exec --interactive mongodb-4 mongo --port 27017 --shell
# fi

if [ "$CMD" = "create-db" ]; then
  # Check if required parameters are provided
  if [ -z "$DATABASE" ]; then
    echo "Usage: $0 create-db --database=<database-name>"
    exit 1
  fi

  # Create a default user
  USERNAME="${DATABASE}_default_user"
  APP_ROLE="${DATABASE}_app_role"
  ADMIN_ROLE="${DATABASE}_admin_role"
  PASSWORD=$(head -c 24 /dev/urandom | base64)

  # Create role and user in MongoDB
  podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
    // First check if database exists using currentOp instead of listDatabases
    let db = db.getSiblingDB('$DATABASE');
    if (currentDb !== undefined) {
      let dbExists = currentDb.stats().ok;
      if (dbExists) {
        print('Database "$DATABASE" already exists');
        quit(1);
      }
    }

    // Create the database, but remove the collection immediately
    db.createCollection('temp');
    db.temp.drop();
    
    // Create roles
    db.createRole({
      role: '${APP_ROLE}',
      privileges: [
        {
          resource: { db: '$DATABASE', collection: '' },
          actions: [ 'find', 'insert', 'update', 'remove', "createCollection", "createIndex" ]
        }
      ],
      roles: [],
      authenticationRestrictions: []
    });
    
    // Create user with the generated password
    db.createUser({
      user: '$USERNAME',
      pwd: '$PASSWORD',
      roles: [{ "role": "${APP_ROLE}", "db": "$DATABASE" }],
      mechanisms: [ "SCRAM-SHA-256" ],
      passwordDigestor: "server",
    });
EOF
)"
  
  # Check the result of the MongoDB command
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo mongodb://$USERNAME:$PASSWORD@[%%$(hostname)%%]:27017/$DATABASE
  else
    echo "Failed to create user (Error code: $RESULT)"
    exit 1
  fi
fi

if [ "$CMD" = "create-admin" ]; then
  # Check if required parameters are provided
  if [ -z "$DATABASE" ] || [ -z "$USERNAME" ]; then
    echo "Usage: $0 create-admin --database=<database-name> --username=<name>"
    exit 1
  fi

  ADMIN_ROLE="${DATABASE}_admin_role"
  PASSWORD=$(head -c 24 /dev/urandom | base64)

  # Create role and user in MongoDB
  podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
    db = db.getSiblingDB('$DATABASE');

    db.createRole({
      role: '${ADMIN_ROLE}',
      privileges: [
        {
          resource: { db: '$DATABASE', collection: '' },
          actions: ["find", "insert", "remove", "update", "compact", "createCollection", "dropCollection", "collStats", "createIndex", "reIndex", "dropIndex"]
        }
      ],
      roles: [],
      authenticationRestrictions: []
    });
    
    // Create user with the generated password
    db.createUser({
      user: '$USERNAME',
      pwd: '$PASSWORD',
      roles: ['${ADMIN_ROLE}']
    });
EOF
)"
  
  # Check the result of the MongoDB command
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo mongodb://$USERNAME:$PASSWORD@[%%$(hostname)%%]:27017/$DATABASE
  else
    echo "Failed to create user (Error code: $RESULT)"
    exit 1
  fi
fi

if [ "$CMD" = "change-password" ]; then
  if [ -z "$USERNAME" ] || [ -z "$DATABASE" ]; then
    echo "Usage: $0 change-password --username=<username> --database=<database>"
    exit 1
  fi

  # Generate random password if not provided
  NEW_PASSWORD=$(head -c 24 /dev/urandom | base64)
  
  podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
    db = db.getSiblingDB('$DATABASE');
    
    // Check if user exists
    let userExists = db.getUser('$USERNAME');
    if (!userExists) {
      print('Error: User "$USERNAME" does not exist in database "$DATABASE"');
      quit(1);
    }
    
    // Change password
    db.changeUserPassword('$USERNAME', '$NEW_PASSWORD');
EOF
)"

  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo mongodb://$USERNAME:$NEW_PASSWORD@[%%$(hostname)%%]:27017/$DATABASE
  else
    echo "Failed to change password (Error code: $RESULT)"
    exit 1
  fi
fi

if [ "$CMD" = "users" ]; then
  if [ -z "$DATABASE" ]; then
    podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
      let adminDb = db.getSiblingDB('admin');
      let cursor = adminDb.system.users.find();
      let userCount = 0;
      
      print('\nAll Database Users:');
      print('==================');
      
      while(cursor.hasNext()) {
        let user = cursor.next();
        userCount++;
        
        print('\nUsername: ' + user.user);
        print('Database: ' + user.db);
        print('Roles:');
        user.roles.forEach(role => {
          print('  - ' + role.role + ' (database: ' + role.db + ')');
        });
        print('User ID: ' + user.userId);
        print('------------------');
      }
      
      if (userCount === 0) {
        print('No users found');
      } else {
        print('\nTotal users: ' + userCount);
      }
EOF
)"
  else
    podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
      let adminDb = db.getSiblingDB('admin');
      let cursor = adminDb.system.users.find({ 'db': '$DATABASE' });
      let userCount = 0;
      
      print('\nUsers in database "$DATABASE":');
      print('================================');
      
      while(cursor.hasNext()) {
        let user = cursor.next();
        userCount++;
        
        print('\nUsername: ' + user.user);
        print('Roles:');
        user.roles.forEach(role => {
          print('  - ' + role.role + ' (database: ' + role.db + ')');
        });
        print('User ID: ' + user.userId);
        print('--------------------------------');
      }
      
      if (userCount === 0) {
        print('No users found in database "$DATABASE"');
      } else {
        print('\nTotal users: ' + userCount);
      }

EOF
)"
  fi


  RESULT=$?
  if [ $RESULT -ne 0 ]; then
    echo "Failed to retrieve users (Error code: $RESULT)"
    exit 1
  fi
fi

if [ "$CMD" = "delete-user" ]; then
  if [ -z "$USERNAME" ] || [ -z "$DATABASE" ]; then
    echo "Usage: $0 delete-user <username> --database=<database> [--force]"
    echo "Use --force to skip confirmation prompt"
    exit 1
  fi

  # Check confirmation unless --force is used
  if [ "$FORCE" != "true" ]; then
    read -p "Are you sure you want to delete user '$USERNAME' from database '$DATABASE'? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Operation cancelled"
      exit 1
    fi
  fi

  podman exec mongodb-4 mongo --quiet --port 27017 --eval "$(cat <<EOF
    const adminDb = db.getSiblingDB('admin');
      
    // First check if user exists and get their roles
    const user = adminDb.system.users.findOne({ 
      user: '$USERNAME', 
      db: '$DATABASE'
    });
    
    if (!user) {
      print('Error: User "$USERNAME" does not exist in database "$DATABASE"');
      quit(1);
    }
    
    // Store roles for confirmation message
    const roles = user.roles;
    
    // Switch to target database to drop user
    const targetDb = db.getSiblingDB('$DATABASE');
    targetDb.dropUser('$USERNAME');
    
    print('User "$USERNAME" successfully deleted from database "$DATABASE"');
    print('The user had the following roles:');
    roles.forEach(role => {
      print('  - ' + role.role + (role.db !== '$DATABASE' ? ' (database: ' + role.db + ')' : ''));
    });
EOF
)"

  RESULT=$?
  if [ $RESULT -ne 0 ]; then
    echo "Failed to delete user (Error code: $RESULT)"
    exit 1
  fi
fi
