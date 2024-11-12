#!/usr/bin/env bash

if [[ "init status dbs" == *"$1"* ]]; then
  CMD="$1"
else
  exit 0
fi

if [ "$CMD" = "init" ]; then
  echo "Initializing MongoDB replica set"
  podman exec mongodb-4 mongo --port 27017 --eval "rs.initiate({_id: \"rs0\", members: [{_id: 0, host: \"$service001\", priority: 100},{_id: 1, host: \"$service002\"},{_id: 2, host: \"$service003\"}]})"
  echo "Result Code: $?"
fi

if [ "$CMD" = "status" ]; then
  podman exec mongodb-4 mongo --port 27017 --eval 'rs.status()'
  echo "Result Code: $?"
fi

if [ "$CMD" = "dbs" ]; then
  podman exec mongodb-4 mongo --port 27017 --eval "db = new Mongo().getDB('admin'); db.adminCommand({'listDatabases': 1})"
fi

# The action command is currently not interactive
# if [ "$CMD" = "shell" ]; then
#   podman exec --interactive mongodb-4 mongo --port 27017 --shell
# fi
