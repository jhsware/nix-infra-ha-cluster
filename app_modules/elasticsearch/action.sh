#!/usr/bin/env bash

##
if [[ "init indices status" == *"$1"* ]]; then
  CMD="$1"
else
  exit 0
fi

IP_ADDR=$(ifconfig flannel-wg | grep inet | awk '$1=="inet" {print $2}')
URI=https://$IP_ADDR:9200

if [ "$CMD" = "init" ]; then
  # TODO: Make sure security is enabled
  # TODO: Create management user/password
  # https://www.elastic.co/guide/en/elasticsearch/reference/8.15/security-minimal-setup.html
  podman exec elasticsearch ./bin/elasticsearch-reset-password -u elastic
  # > password
fi

if [ "$CMD" = "indices" ]; then
  # curl -s -X GET -H "Content-Type: application/json" "$URI/?human&pretty"
  curl -k -s -X GET -H "Content-Type: application/json" "$URI/_cat/indices?v"
fi

if [ "$CMD" = "status" ]; then
  curl -k -s -X GET -H "Content-Type: application/json" "$URI/?human&pretty"
  # curl -k -s -X GET -H "Content-Type: application/json" "$URI/_cluster/health?human&pretty"
fi
