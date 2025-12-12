#!/usr/bin/env bash

if [[ "status users" == *"$1"* ]]; then
  CMD="$1"
else
  exit 0
fi

for i in "$@"; do
  case $i in
    --admin-password=*)
    ADMIN_PASSWORD="${i#*=}"
    shift
    ;;
  esac
done

if [ "$CMD" = "status" ]; then
  [ -z "$ADMIN_PASSWORD" ] && echo "Missing --admin-password" && exit -1
  podman exec keydb-ha keydb-cli -a $ADMIN_PASSWORD -p 6380 ping
fi

if [ "$CMD" = "users" ]; then
  [ -z "$ADMIN_PASSWORD" ] && echo "Missing --admin-password" && exit -1
  podman exec keydb-ha keydb-cli -h 127.0.0.1 -p 6380 -a $ADMIN_PASSWORD ACL LIST
fi
