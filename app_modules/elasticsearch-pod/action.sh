#!/usr/bin/env bash

_mute=/dev/null

if [[ "init status apps create-app delete-app users create-admin change-password" == *"$1"* ]]; then
  CMD="$1"
else
  exit 0
fi

for i in "$@"; do
  case $i in
    --app=*)
    APP_NAME="${i#*=}"
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

if [ "$CMD" = "init" ]; then
  echo "Initializing Elasticsearch security settings"
  echo "NOTE: This will only work once we change to 'xpack.security.enabled: true' and fix security setup"
  # https://www.elastic.co/guide/en/elasticsearch/reference/current/manually-configure-security.html
  curl -s localhost:9200/_cluster/health
  podman exec -t elasticsearch ./bin/elasticsearch-reset-password -u elastic --auto --batch # --silent
  echo "Result Code: $?"
fi

# Get the IP address for the Elasticsearch instance
IP_ADDR=$(ifconfig flannel-wg | grep inet | awk '$1=="inet" {print $2}')
URI=http://$IP_ADDR:9200
AUTH_HEADER="Authorization: Basic $(echo -n "elastic:${ELASTIC_PASSWORD}" | base64)"

if [ "$CMD" = "status" ]; then
  # curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" "$URI/_cluster/health?pretty"
  echo $URI
  curl -k -s -X GET -H "Content-Type: application/json" "$URI/?human&pretty"
fi

if [ "$CMD" = "create-app" ]; then
  if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 create-app --app=<app-name>"
    exit 1
  fi

  # Create regular app role with restricted permissions
  read -r -d '' app_role_json <<EOF || true
{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["${APP_NAME}-*"],
      "privileges": ["read", "write", "view_index_metadata"],
      "allow_restricted_indices": false
    }
  ]
}
EOF
  curl -k -s -X PUT -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/role/${APP_NAME}_app_role" -d "$app_role_json" >$_mute

  # Create admin role with additional privileges
  read -r -d '' admin_role_json <<EOF || true
{
  "cluster": ["monitor", "manage_index_templates", "manage_ilm"],
  "indices": [
    {
      "names": ["${APP_NAME}-*"],
      "privileges": ["all"],
      "allow_restricted_indices": false
    }
  ]
}
EOF
  curl -k -s -X PUT -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/role/${APP_NAME}_admin_role" -d "$admin_role_json" >$_mute

  # Generate password for default user
  DEFAULT_USER="${APP_NAME}_default_user"
  DEFAULT_PASSWORD=$(head -c 24 /dev/urandom | base64)

  # Create default user with app role
  read -r -d '' user_json <<EOF || true
{
  "password": "$DEFAULT_PASSWORD",
  "roles": ["${APP_NAME}_app_role"],
  "full_name": "Default user for ${APP_NAME}",
  "enabled": true
}
EOF
  curl -k -s -X POST -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/user/$DEFAULT_USER" -d "$user_json" >$_mute

  # Return connection string
  echo "https://${DEFAULT_USER}:${DEFAULT_PASSWORD}@${IP_ADDR}:9200/${APP_NAME}-*"
fi

if [ "$CMD" = "create-admin" ]; then
  if [ -z "$USERNAME" ] || [ -z "$APP_NAME" ]; then
    echo "Usage: $0 create-admin --app=<app-name> --username=<name>"
    exit 1
  fi

  # Generate password for admin user
  ADMIN_PASSWORD=$(head -c 24 /dev/urandom | base64)

  # # Check if app roles exist
  # role_exists=$(curl -k -s -X GET -H "$AUTH_HEADER" "$URI/_security/role/${APP_NAME}_admin_role" | jq 'has("${APP_NAME}_admin_role")')
  # if [ "$role_exists" != "true" ]; then
  #   echo "Error: App '${APP_NAME}' does not exist"
  #   exit 1
  # fi

  read -r -d '' user_json <<EOF || true
{
  "password": "$ADMIN_PASSWORD",
  "roles": ["${APP_NAME}_admin_role"],
  "full_name": "$USERNAME (${APP_NAME} admin user)",
  "enabled": true
}
EOF
  curl -k -s -X POST -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/user/$USERNAME" -d "$user_json" >$_mute
  
  # Return connection string
  echo "https://${USERNAME}:${ADMIN_PASSWORD}@${IP_ADDR}:9200/${APP_NAME}-*"
fi

if [ "$CMD" = "change-password" ]; then
  if [ -z "$USERNAME" ]; then
    echo "Usage: $0 change-password --username=<name>"
    exit 1
  fi

  # Generate new secure password
  NEW_PASSWORD=$(head -c 24 /dev/urandom | base64)

  # Update the user's password
  read -r -d '' password_json <<EOF || true
{
  "password": "$NEW_PASSWORD"
}
EOF
  curl -k -s -X POST -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/user/$USERNAME/_password" -d "$password_json" >$_mute
  
  # Get user's roles to determine if they are associated with an app
  user_info=$(curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/user/$USERNAME")
  
  app_role=$(echo "$user_info" | jq -r '.roles[] | select(endswith("_app_role") or endswith("_admin_role"))' | sed 's/_\(app\|admin\)_role$//')
  
  if [ ! -z "$app_role" ]; then
    echo "https://${USERNAME}:${NEW_PASSWORD}@${IP_ADDR}:9200/${app_role}-*"
  else
    echo "https://${USERNAME}:${NEW_PASSWORD}@${IP_ADDR}:9200"
  fi
fi

if [ "$CMD" = "delete-app" ]; then
  if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 delete-app --app=<app-name> [--force]"
    exit 1
  fi

  if [ "$FORCE" != "true" ]; then
    read -p "Are you sure you want to delete app '$APP_NAME', its roles and users? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Operation cancelled"
      exit 1
    fi
  fi

  # Get list of users with app roles
  users=$(curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" \
    "$URI/_security/user" | jq -r "to_entries | map(select(.value.roles[] | contains(\"${APP_NAME}_app_role\") or contains(\"${APP_NAME}_admin_role\"))) | map(.key)[]")

  # Delete all users associated with the app
  for user in $users; do
    curl -k -s -X DELETE -H "$AUTH_HEADER" "$URI/_security/user/$user" >$_mute
  done

  # Delete the app roles
  curl -k -s -X DELETE -H "$AUTH_HEADER" "$URI/_security/role/${APP_NAME}_app_role" >$_mute
  curl -k -s -X DELETE -H "$AUTH_HEADER" "$URI/_security/role/${APP_NAME}_admin_role" >$_mute
  
  echo "Deleted app '$APP_NAME' with all associated roles and users"
fi

if [ "$CMD" = "apps" ]; then
  if [ -z "$VERBOSE" ]; then
    # List app names by looking at role patterns
    curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" \
      "$URI/_security/role" | jq -r 'keys[] | select(. | endswith("_app_role"))' | sed 's/_app_role$//'
  else
    # Show detailed information about each app including indices and users
    roles=$(curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" "$URI/_security/role")
    users=$(curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" "$URI/_security/user")
    
    echo "Application Details:"
    echo "==================="
    
    echo "$roles" | jq -r 'keys[] | select(. | endswith("_app_role"))' | sed 's/_app_role$//' | while read app; do
      echo -e "\nApp: $app"
      echo "--------------------"
      echo "Indices:"
      echo "$roles" | jq -r ".[\"${app}_app_role\"].indices[].names[]"
      echo -e "\nUsers:"
      echo "$users" | jq -r "to_entries[] | select(.value.roles[] | contains(\"${app}_app_role\")) | .key"
      echo "--------------------"
    done
  fi
fi

if [ "$CMD" = "users" ]; then
  if [ -z "$APP_NAME" ]; then
    # List all users and their app roles
    curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" \
      "$URI/_security/user" | jq 'to_entries | map({username: .key, roles: .value.roles}) | .[]'
  else
    # List users for specific app
    curl -k -s -X GET -H "Content-Type: application/json" -H "$AUTH_HEADER" \
      "$URI/_security/user" | jq "to_entries | map(select(.value.roles[] | contains(\"${APP_NAME}_app_role\") or contains(\"${APP_NAME}_admin_role\"))) | map({username: .key, roles: .value.roles}) | .[]"
  fi
fi
