#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORK_DIR=${WORK_DIR:-$(dirname "$SCRIPT_DIR")}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
SSH_KEY="nixinfra"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}
ENV=${ENV:-.env}
NIXOS_VERSION=${NIXOS_VERSION:-"24.11"}

if [[ "create upgrade destroy version" == *"$1"* ]]; then
  CMD="$1"
  shift
fi

NODES="etcd001"

_start=$(date +%s)
if [ "$CMD" = "create" ]; then

  $NIX_INFRA init -d "$WORK_DIR" --batch
  # We need to add the ssh-key for it to work for some reason
  ssh-add "$WORK_DIR"/ssh/$SSH_KEY
  
  # Provision the test cluster
  $NIX_INFRA cluster provision -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
      --nixos-version="$NIXOS_VERSION" \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$NODES"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nixos-version"
fi

if [ "$CMD" = "destroy" ]; then
  $NIX_INFRA cluster destroy -d "$WORK_DIR" --batch \
      --target="$NODES" \
      --ctrl-nodes="$NODES"
      
  $NIX_INFRA ssh-key remove -d "$WORK_DIR" --batch --name="$SSH_KEY"

  echo "Remove /ca and /ssh..."
  rm -rf "$WORK_DIR/ca"
  rm -rf "$WORK_DIR/ssh"
fi

if [ "$CMD" = "upgrade" ]; then
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nixos-version"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nix-channel --add https://nixos.org/channels/nixos-$NIXOS_VERSION nixos"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nix-channel --update"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nixos-rebuild switch"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nixos-version"
fi

if [ "$CMD" = "version" ]; then
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$NODES" "nixos-version"
fi

_end=$(date +%s)
printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
}
echo "******************************************"
printf '= SUM %s\n' $(printTime $_start $_end)
echo "***************** DONE *******************"