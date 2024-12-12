#!/usr/bin/env bash

if [[ "init status dbs create-db create-admin delete-user list-users change-password" == *"$1"* ]]; then
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
  podman exec mongodb-4 mongo --port 27017 --eval 'rs.status()'
  echo "Result Code: $?"
fi

if [ "$CMD" = "dbs" ]; then
  if [ -z "$VERBOSE" ]; then
    podman exec mongodb-4 mongo --port 27017 --eval "db = new Mongo().getDB('admin'); db.adminCommand({'listDatabases': 1})"
  else
    podman exec mongodb-4 mongo --port 27017 --eval "$(cat <<EOF
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
  USERNAME="$DATABASE_default_user"
  APP_ROLE=${DATABASE}_app_role
  ADMIN_ROLE=${DATABASE}_admin_role
  PASSWORD=$(openssl rand -base64 24)

  # Create role and user in MongoDB
  podman exec mongodb-4 mongo --port 27017 --eval "$(cat <<EOF
    let dbs = db.adminCommand('listDatabases');
    let dbExists = dbs.databases.some(db => db.name === '$DATABASE_NAME');

    if (dbExists) {
      print('Database \"$DATABASE_NAME\" already exists');
      quit(1);
    }

    db = db.getSiblingDB('$DATABASE');
    
    // Create roles
    db.createRole({
      role: '${APP_ROLE}',
      privileges: [
        {
          resource: { db: '$DATABASE', collection: '' },
          actions: [ 'find', 'insert', 'update', 'remove', "createCollection", "createIndex" ]
        }
      ],
      roles: []
    });
    db.createRole({
      role: '${ADMIN_ROLE}',
      privileges: [
        {
          resource: { db: '$DATABASE', collection: '' },
          actions: ["find", "insert", "remove", "update", "compact", "createCollection", "dropCollection", "collStats", "createIndex", "reIndex", "dropIndex"]
        }
      ],
      roles: []
    });
    
    // Create user with the generated password
    db.createUser({
      user: '$USERNAME',
      pwd: '$PASSWORD',
      roles: ['${APP_ROLE}']
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

  ADMIN_ROLE=${DATABASE}_admin_role
  PASSWORD=$(openssl rand -base64 24)

  # Create role and user in MongoDB
  podman exec mongodb-4 mongo --port 27017 --eval "$(cat <<EOF
    db = db.getSiblingDB('$DATABASE');
    
    // Create user with the generated password
    db.createUser({
      user: '$USERNAME',
      pwd: '$PASSWORD',
      roles: ['${APP_ROLE}']
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
  NEW_PASSWORD=$(openssl rand -base64 24)
  
  podman exec mongodb-4 mongo --port 27017 --eval "$(cat <<EOF
    db = db.getSiblingDB('$DATABASE');
    
    // Check if user exists
    let userExists = db.getUser('$USERNAME');
    if (!userExists) {
      print('Error: User \"$USERNAME\" does not exist in database \"$DATABASE\"');
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

if [ "$CMD" = "list-users" ]; then
  if [ -z "$DATABASE" ]; then
    echo "Usage: $0 list-users --database=<database>"
    exit 1
  fi

  podman exec mongodb-4 mongo --port 27017 --eval "$(cat <<EOF
    db = db.getSiblingDB('$DATABASE');
    
    // Get all users for the database
    let users = db.getUsers();
    if (users.users.length === 0) {
      print('No users found in database \"$DATABASE\"');
      quit(0);
    }
    
    print('\nUsers in database \"$DATABASE\":');
    print('================================');
    
    users.users.forEach(user => {
      print('\nUsername: ' + user.user);
      print('Roles:');
      user.roles.forEach(role => {
        print('  - ' + role.role + (role.db !== '$DATABASE' ? ' (database: ' + role.db + ')' : ''));
      });
      print('User ID: ' + user.userId);
      print('--------------------------------');
    });
EOF
)"

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

  podman exec mongodb-4 mongo --port 27017 --eval "$(cat <<EOF
    db = db.getSiblingDB('$DATABASE');
    
    // Check if user exists
    let userInfo = db.getUser('$USERNAME');
    if (!userInfo) {
      print('Error: User \"$USERNAME\" does not exist in database \"$DATABASE\"');
      quit(1);
    }
    
    // Store user info for confirmation message
    let roles = userInfo.roles;
    
    // Delete the user
    db.dropUser('$USERNAME');
    
    print('User \"$USERNAME\" successfully deleted from database \"$DATABASE\"');
    print('The following roles were removed:');
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
