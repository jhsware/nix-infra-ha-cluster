#!/usr/bin/env bash
appendWithLineBreak() {
  if [ -z "$1" ]; then
    printf '%s' "$2"
  else
    printf '%s\n%s' "$1" "$2"
  fi
}

cmd () {
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$1" "$2"
}

# Common commands "pull ssh action cmd etcd"

if [ "$CMD" = "pull" ]; then
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i "$WORK_DIR"/ssh/$SSH_KEY
  git -C "$WORK_DIR" pull
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i "$WORK_DIR"/ssh/$SSH_KEY
  $NIX_INFRA cluster ssh -d "$WORK_DIR" --target="$REST"
  exit 0
fi

if [ "$CMD" = "action" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 action [target] [cmd]"
    exit 1
  fi
  
  read -r module cmd < <(echo "$REST")
  _target=${TARGET:-"service001"}
  # (cd "$WORK_DIR" && git fetch origin && git reset --hard origin/$(git branch --show-current))
  $NIX_INFRA cluster action -d "$WORK_DIR" --target="$_target" --app-module="$module" \
    --cmd="$cmd" # --env-vars="ELASTIC_PASSWORD="
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "etcd" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 etcd --env=$ENV [services | frontends | backends | network | nodes]"
    exit 1
  fi
  $NIX_INFRA cluster etcd "$REST" -d "$WORK_DIR" --target="$CTRL_NODES"
  exit 0
fi

# Test helpers 

checkNixos() {
  echo "Checking NixOS"
  local NODES="$1"
  local node
  local _nixos_fail=""

  for node in $NODES; do
    local output=$(cmd "$node" "uname -a" 2>&1)
    if [[ "$output" == *"NixOS"* ]]; then
      echo "- nixos    : ok ($node)"
    else
      echo "- nixos    : fail ($node)"
      if [ -n "$output" ]; then
        echo "$output"
      fi
      _nixos_fail="true";
    fi
  done

  if [ -n "$_nixos_fail" ]; then
    return 1
  fi
}

checkEtcd() {
  echo "Checking etcd"
  local NODES="$1" # ETCD nodes
  local node
  local _failed

  for node in $NODES; do
    local output=$(cmd "$node" "systemctl is-active etcd" 2>&1)
    if [[ "$output" == *"active"* ]]; then
      echo "- etcd     : ok ($node)"
    else
      echo "- etcd     : down ($node)"
      if [ -n "$output" ]; then
        echo "$output"
      fi
      _failed="yes"
    fi
  done

  if [ -n "$_failed" ]; then
    return 1
  fi
}

checkWireguard() {
  echo "Checking wireguard"
  local NODES="$1"
  local node
  local _failed

  for node in $NODES; do
    local output=$(cmd "$node" "wg show" 2>&1)
    if [[ "$output" == *"peer: "* ]]; then
      echo "- wireguard: ok ($node)"
    else
      echo "- wireguard: down ($node)"
      if [ -n "$output" ]; then
        echo "$output"
      fi
      _failed="yes"
    fi
  done

  if [ -n "$_failed" ]; then
    return 1
  fi
}

checkConfd() {
  echo "Checking confd"
  local NODES="$1"
  local node
  local _failed

  for node in $NODES; do
    local output=$(cmd "$node" "grep -q \"$node\" /root/test.txt && echo true" 2>&1)
    if [[ "$output" == *"true"* ]]; then
      echo "- confd: ok ($node)"
    else
      echo "- confd: down ($node)"
      if [ -n "$output" ]; then
        echo "$output"
      fi
      _failed="yes"
    fi
  done
  
  if [ -n "$_failed" ]; then
    return 1
  fi
}
