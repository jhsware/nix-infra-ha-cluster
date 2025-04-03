#!/usr/bin/env bash

_mute=/dev/null

if [[ "init status dbs create-db create-admin delete-user users change-password" == *"$1"* ]]; then
  CMD="$1"
else
  echo "Usage: $0 [init|status|dbs|create-db|create-admin|delete-user|users|change-password] [options]"
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
    _mute=/dev/stdout
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

MARIADB_CONTAINER="mariadb-cluster"
MARIADB_ROOT_USER="root"
MARIADB_ROOT_PASSWORD=$(podman exec $MARIADB_CONTAINER printenv MARIADB_ROOT_PASSWORD || echo "")

# Helper function to execute MariaDB commands
execute_mariadb_query() {
  local query="$1"
  local database="${2:-mysql}"
  
  podman exec $MARIADB_CONTAINER mysql -u$MARIADB_ROOT_USER -p"$MARIADB_ROOT_PASSWORD" $database -e "$query"
  return $?
}

if [ "$CMD" = "init" ]; then
  echo "Initializing MariaDB Galera cluster"
  
  # Check if we're initializing the first node or joining an existing cluster
  if [ -n "$NODE_1" ]; then
    echo "Initializing first node and bootstrapping the cluster"
    podman exec $MARIADB_CONTAINER mysql -u$MARIADB_ROOT_USER -p"$MARIADB_ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
  else
    echo "Node already part of a cluster or not properly configured"
  fi
  echo "Result Code: $?"
fi

if [ "$CMD" = "status" ]; then
  echo "Cluster Status:"
  podman exec $MARIADB_CONTAINER mysql -u$MARIADB_ROOT_USER -p"$MARIADB_ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep%';"
  echo "Result Code: $?"
fi

if [ "$CMD" = "dbs" ]; then
  echo "Databases..."
  if [ -z "$VERBOSE" ]; then
    execute_mariadb_query "SHOW DATABASES;" 
  else
    echo -e "\nDatabase List:"
    echo "============="
    
    # Get list of databases with size information
    podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
      SELECT 
        table_schema AS 'Database', 
        ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
      FROM information_schema.tables
      GROUP BY table_schema
      ORDER BY table_schema;
    \""
    
    # Get total size and count
    podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
      SELECT 
        CONCAT('Total size: ', ROUND(SUM(data_length + index_length) / 1024 / 1024, 2), ' MB') AS '',
        CONCAT('Total number of databases: ', COUNT(DISTINCT table_schema)) AS ''
      FROM information_schema.tables;
    \""
  fi
fi

if [ "$CMD" = "create-db" ]; then
  # Check if required parameters are provided
  if [ -z "$DATABASE" ]; then
    echo "Usage: $0 create-db --database=<database-name>"
    exit 1
  fi

  # Create a default user
  USERNAME="${DATABASE}_default_user"
  PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)

  # Create database and user in MariaDB
  DB_CREATE_RESULT=$(podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
    CREATE DATABASE IF NOT EXISTS \\\`$DATABASE\\\`;
    CREATE USER '$USERNAME'@'%' IDENTIFIED BY '$PASSWORD';
    GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, INDEX, DROP, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES ON \\\`$DATABASE\\\`.* TO '$USERNAME'@'%';
    FLUSH PRIVILEGES;
  \"" 2>&1)
  
  # Check the result of the MariaDB command
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo mysql://$USERNAME:$PASSWORD@[%%$(hostname)%%]:3306/$DATABASE
  else
    echo "Failed to create database/user (Error code: $RESULT)"
    echo "$DB_CREATE_RESULT"
    exit 1
  fi
fi

if [ "$CMD" = "create-admin" ]; then
  # Check if required parameters are provided
  if [ -z "$DATABASE" ] || [ -z "$USERNAME" ]; then
    echo "Usage: $0 create-admin --database=<database-name> --username=<name>"
    exit 1
  fi

  PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)

  # Create admin user in MariaDB
  ADMIN_CREATE_RESULT=$(podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
    CREATE DATABASE IF NOT EXISTS \\\`$DATABASE\\\`;
    CREATE USER '$USERNAME'@'%' IDENTIFIED BY '$PASSWORD';
    GRANT ALL PRIVILEGES ON \\\`$DATABASE\\\`.* TO '$USERNAME'@'%';
    FLUSH PRIVILEGES;
  \"" 2>&1)
  
  # Check the result of the MariaDB command
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo mysql://$USERNAME:$PASSWORD@[%%$(hostname)%%]:3306/$DATABASE
  else
    echo "Failed to create admin user (Error code: $RESULT)"
    echo "$ADMIN_CREATE_RESULT"
    exit 1
  fi
fi

if [ "$CMD" = "change-password" ]; then
  if [ -z "$USERNAME" ]; then
    echo "Usage: $0 change-password --username=<username> [--database=<database>]"
    exit 1
  fi

  # Generate random password
  NEW_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
  
  # Change password in MariaDB
  CHANGE_PW_RESULT=$(podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
    /* First check if the user exists */
    SELECT COUNT(*) INTO @user_exists FROM mysql.user WHERE user = '$USERNAME';
    
    /* If the user doesn't exist, this will produce an error */
    SET @query = IF(@user_exists > 0, 
      'ALTER USER \\'$USERNAME\\'@\\'%\\' IDENTIFIED BY \\'$NEW_PASSWORD\\';', 
      'SELECT \\'Error: User does not exist\\' AS error_message');
    
    PREPARE stmt FROM @query;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    
    FLUSH PRIVILEGES;
  \"" 2>&1)
  
  RESULT=$?
  if [ $RESULT -eq 0 ] && [[ ! "$CHANGE_PW_RESULT" == *"Error: User does not exist"* ]]; then
    if [ -n "$DATABASE" ]; then
      echo mysql://$USERNAME:$NEW_PASSWORD@[%%$(hostname)%%]:3306/$DATABASE
    else
      echo "Password for user '$USERNAME' changed successfully"
      echo "New password: $NEW_PASSWORD"
    fi
  else
    echo "Failed to change password (Error code: $RESULT)"
    echo "$CHANGE_PW_RESULT"
    exit 1
  fi
fi

if [ "$CMD" = "users" ]; then
  echo -e "\nDatabase Users:"
  echo "================"
  
  if [ -z "$DATABASE" ]; then
    # List all users with their privileges
    podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
      SELECT 
        user.User AS 'Username', 
        user.Host AS 'Host',
        GROUP_CONCAT(DISTINCT db.Db SEPARATOR ', ') AS 'Databases'
      FROM mysql.user user
      LEFT JOIN mysql.db db ON user.User = db.User
      WHERE user.User != ''
      GROUP BY user.User, user.Host
      ORDER BY user.User;
      
      SELECT 
        CONCAT('Total users: ', COUNT(*)) AS ''
      FROM mysql.user
      WHERE User != '';
    \""
  else
    # List users with privileges on specific database
    podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
      SELECT 
        user.User AS 'Username', 
        user.Host AS 'Host',
        CONCAT(
          IF(db.Select_priv = 'Y', 'SELECT, ', ''),
          IF(db.Insert_priv = 'Y', 'INSERT, ', ''),
          IF(db.Update_priv = 'Y', 'UPDATE, ', ''),
          IF(db.Delete_priv = 'Y', 'DELETE, ', ''),
          IF(db.Create_priv = 'Y', 'CREATE, ', ''),
          IF(db.Drop_priv = 'Y', 'DROP, ', ''),
          IF(db.Grant_priv = 'Y', 'GRANT, ', ''),
          IF(db.References_priv = 'Y', 'REFERENCES, ', ''),
          IF(db.Index_priv = 'Y', 'INDEX, ', ''),
          IF(db.Alter_priv = 'Y', 'ALTER, ', ''),
          IF(db.Create_tmp_table_priv = 'Y', 'CREATE TEMPORARY TABLES, ', ''),
          IF(db.Lock_tables_priv = 'Y', 'LOCK TABLES, ', '')
        ) AS 'Privileges'
      FROM mysql.user user
      JOIN mysql.db db ON user.User = db.User
      WHERE db.Db = '$DATABASE'
      ORDER BY user.User;
      
      SELECT 
        CONCAT('Total users with access to $DATABASE: ', COUNT(*)) AS ''
      FROM mysql.db
      WHERE Db = '$DATABASE';
    \""
  fi

  RESULT=$?
  if [ $RESULT -ne 0 ]; then
    echo "Failed to retrieve users (Error code: $RESULT)"
    exit 1
  fi
fi

if [ "$CMD" = "delete-user" ]; then
  if [ -z "$USERNAME" ]; then
    echo "Usage: $0 delete-user --username=<username> [--force]"
    echo "Use --force to skip confirmation prompt"
    exit 1
  fi

  # Check confirmation unless --force is used
  if [ "$FORCE" != "true" ]; then
    read -p "Are you sure you want to delete user '$USERNAME'? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Operation cancelled"
      exit 1
    fi
  fi

  # Get user privileges before deletion for confirmation message
  PRIVILEGES=$(podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
    SELECT Db FROM mysql.db WHERE User = '$USERNAME';
  \"" 2>/dev/null)

  # Delete user in MariaDB
  DELETE_USER_RESULT=$(podman exec $MARIADB_CONTAINER bash -c "mysql -u$MARIADB_ROOT_USER -p\"$MARIADB_ROOT_PASSWORD\" -e \"
    DROP USER IF EXISTS '$USERNAME'@'%';
    FLUSH PRIVILEGES;
  \"" 2>&1)
  
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo "User '$USERNAME' successfully deleted"
    if [ -n "$PRIVILEGES" ]; then
      echo "The user had access to the following databases:"
      echo "$PRIVILEGES" | grep -v "Db"
    fi
  else
    echo "Failed to delete user (Error code: $RESULT)"
    echo "$DELETE_USER_RESULT"
    exit 1
  fi
fi
