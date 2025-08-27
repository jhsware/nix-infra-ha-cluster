#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $0)
WORK_DIR=${WORK_DIR:-"."}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"24.11"}
TEMPLATE_REPO=${TEMPLATE_REPO:-"git@github.com:jhsware/nix-infra-test.git"}
TEMPLATE_REPO_BRANCH=${TEMPLATE_REPO_BRANCH:-"main"}
SSH_KEY="nixinfra"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}
ENV=${ENV:-.env}

CERT_MAIL=${CERT_MAIL:-your-email@example.com}
CERT_COUNTRY_CODE=${CERT_COUNTRY_CODE:-SE}
CERT_STATE_PROVINCE=${CERT_STATE_PROVINCE:-Sweden}
CERT_COMPANY=${CERT_COMPANY:-Your COmpany Inc}

CA_PASS=${CA_PASS:-my_ca_password}
INTERMEDIATE_CA_PASS=${INTERMEDIATE_CA_PASS:-my_ca_inter_password}
SECRETS_PWD=${SECRETS_PWD:-my_secrets_password}

CTRL_NODES="etcd001"
SERVICE_NODES="service001 service002 service003"
OTHER_NODES="worker001"

__help_text__=$(cat <<EOF
Examples:

Run the test:

$ bash <(curl -fsSL https://github.com/jhsware/nix-infra-ha-cluster/refs/heads/main/$TEST_DIR/run.sh) --env=.env-test | tee test.log

Run the test from a local development branch:

$ TEMPLATE_REPO=../nix-infra-ha-cluster/ \$TEMPLATE_REPO/$TEST_DIR/run.sh --branch=mariadb-cluster --env=.env-test | tee test.log

...don't tear it down

$ TEMPLATE_REPO=../nix-infra-ha-cluster/ \$TEMPLATE_REPO/$TEST_DIR/test.sh --branch=mariadb-cluster --env=.env-test --no-teardown | tee test.log

# Interact with a node
$0 ssh --env=.env-test service001
$0 cmd --env=.env-test --target=service001 ls -alh

# Query the etcd database
$0 etcd --env=.env-test --target=etcd001 get --prefix /nodes

# The action is hardcoded in this script, edit to try different stuff
$0 action --env=.env-test --target=service001 args to action
EOF
)

if [[ "create-cluster test-cluster teardown-cluster run teardown reset update ssh cmd etcd action" == *"$1"* ]]; then
  CMD="$1"
  shift
fi

for i in "$@"; do
  case $i in
    --help)
    echo "$__help_text__"
    exit 0
    ;;
    --env=*)
    ENV="${i#*=}"
    shift
    ;;
    --target=*)
    TARGET="${i#*=}"
    shift
    ;;
    --branch=*)
    TEMPLATE_REPO_BRANCH="${i#*=}"
    shift
    ;;
    --no-teardown)
    TEARDOWN=no
    shift
    ;;
    --force)
    FORCE=yes
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

if [ "$ENV" != "" ]; then
  source $ENV
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

if [ "$CMD" = "run" ]; then
  if [ ! -d $WORK_DIR ]; then
    echo "Working directory doesn't exist ($WORK_DIR)"
    exit 1
  fi
  TEST_DIR="__test__/$REST" source "$WORK_DIR/__test__/$REST/test.sh"
  exit 0
fi

if [ "$CMD" = "teardown" ]; then
  if [ ! -d $WORK_DIR ]; then
    echo "Working directory doesn't exist ($WORK_DIR)"
    exit 1
  fi
  TEST_DIR="__test__/$REST" source "$WORK_DIR/__test__/$REST/test.sh"
  exit 0
fi

source $SCRIPT_DIR/check.sh

cmd () { # Override the local declaration
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$1" "$2"
}

testCluster() {
  checkNixos "$CTRL_NODES $SERVICE_NODES $OTHER_NODES"
  checkEtcd "$CTRL_NODES"
  checkWireguard "$SERVICE_NODES $OTHER_NODES"
  checkConfd "$SERVICE_NODES $OTHER_NODES"
}

publishImageToRegistry() {
    local IMAGE_NAME=$1
    local FILE=$2
    local IMAGE_TAG=$3
    $NIX_INFRA registry publish-image -d $WORK_DIR --batch \
      --target="worker001" \
      --image-name="$IMAGE_NAME" \
      --image-tag="$IMAGE_TAG" \
      --file="$FILE" \
      --use-localhost
}

tearDownCluster() {
  $NIX_INFRA cluster destroy -d $WORK_DIR --batch \
      --target="$SERVICE_NODES $OTHER_NODES" \
      --ctrl-nodes="$CTRL_NODES"

  $NIX_INFRA cluster destroy -d $WORK_DIR --batch \
      --target="$CTRL_NODES" \
      --ctrl-nodes="$CTRL_NODES"

  $NIX_INFRA ssh-key remove -d $WORK_DIR --batch --name="$SSH_KEY"
}

cleanupOnFail() {
  if [ $1 -ne 0 ]; then
    echo "$2"
    tearDownCluster
    exit 1
  fi
}

if [ "$CMD" = "teardown-cluster" ]; then
  tearDownCluster
  exit 0
fi

if [ "$CMD" = "update" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 update --env=$ENV [node1 node2 ...]"
    exit 1
  fi
  (cd "$WORK_DIR" && git fetch origin && git reset --hard origin/$(git branch --show-current))

  $NIX_INFRA cluster update-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
    --nixos-version=$NIXOS_VERSION \
    --node-module="node_types/cluster_node.nix" \
    --ctrl-nodes="$CTRL_NODES" \
    --target="$SERVICE_NODES $OTHER_NODES"
  exit 0
fi

if [ "$CMD" = "reset" ]; then
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$SERVICE_NODES $OTHER_NODES" "rm -f /etc/nixos/$(hostname).nix"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$SERVICE_NODES $OTHER_NODES" "nixos-rebuild switch --fast"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$SERVICE_NODES $OTHER_NODES" "systemctl restart confd"

  sleep 3

  $NIX_INFRA cluster etcd ctl "del --prefix /cluster/services" -d $WORK_DIR --target="$CTRL_NODES"
  $NIX_INFRA cluster etcd ctl "del --prefix /cluster/backends" -d $WORK_DIR --target="$CTRL_NODES"
  $NIX_INFRA cluster etcd ctl "del --prefix /cluster/frontends" -d $WORK_DIR --target="$CTRL_NODES"
  exit 0
fi

if [ "$CMD" = "test-cluster" ]; then
  testCluster
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  # Fallback if ssh terminal isn't working as expected:
  # HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i $WORK_DIR/ssh/$SSH_KEY
  $NIX_INFRA cluster ssh -d $WORK_DIR --target="$REST"
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
  $NIX_INFRA cluster action -d $WORK_DIR --target="$_target" --app-module="$module" \
    --cmd="$cmd" # --env-vars="ELASTIC_PASSWORD="
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "etcd" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 etcd --env=$ENV [services | frontends | backends | network | nodes]"
    exit 1
  fi
  $NIX_INFRA cluster etcd $REST -d $WORK_DIR --target="$CTRL_NODES"
  exit 0
fi

if [ "$CMD" = "create-cluster" ]; then
  if [ -d $WORK_DIR ]; then
    if [ "$FORCE" != "yes" ]; then
      echo "Test directory already exists! Exiting..."
      exit 1
    fi
    rm -rf $WORK_DIR;
  fi
  git clone -b $TEMPLATE_REPO_BRANCH $TEMPLATE_REPO $WORK_DIR

  env=$(cat <<EOF
# NOTE: The following secrets are required for various operations
# by the nix-infra CLI. Make sure they are encrypted when not in use
SSH_KEY=$(echo $SSH_KEY)
SSH_EMAIL=$(echo $SSH_EMAIL)

# The following token is needed to perform provisioning and discovery
HCLOUD_TOKEN=$(echo $HCLOUD_TOKEN)

# Certificate Authority
CERT_EMAIL=$(echo $CERT_MAIL)
CERT_COUNTRY_CODE=$(echo $CERT_COUNTRY_CODE)
CERT_STATE_PROVINCE=$(echo $CERT_STATE_PROVINCE)
CERT_COMPANY=$(echo $CERT_COMPANY)
# Root password for the created certificate authority and CA intermediate.
# This needs to be kept secret and should not be stored here in a real deployment!
CA_PASS=$(echo $CA_PASS)
# The intermediate can be revoked so while it needs to be kept secret, it is less
# of a risk than the root password
INTERMEDIATE_CA_PASS=$(echo $INTERMEDIATE_CA_PASS)

# Password for the secrets that are stored in this repo
# These need to be kept secret.
SECRETS_PWD=$(echo $SECRETS_PWD)
EOF
)
  echo "$env" > $WORK_DIR/.env

  _start=`date +%s`

  $NIX_INFRA init -d $WORK_DIR --batch

  # We need to add the ssh-key for it to work for some reason
  ssh-add $WORK_DIR/ssh/$SSH_KEY

  # Provision the test cluster
  $NIX_INFRA cluster provision -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type=cpx21 \
      --node-names="$CTRL_NODES $SERVICE_NODES $OTHER_NODES"

  cleanupOnFail $? "ERROR: Provisioning failed! Cleaning up..."

  _provision=`date +%s`

  $NIX_INFRA cluster init-ctrl -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --cluster-uuid="d6b76143-bcfa-490a-8f38-91d79be62fab" \
      --target="$CTRL_NODES"

  sleep 3 # allow etcd to start

  $NIX_INFRA cluster init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="$SERVICE_NODES" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="services" \
      --ctrl-nodes="$CTRL_NODES"

  $NIX_INFRA cluster init-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
      --nixos-version=$NIXOS_VERSION \
      --target="$OTHER_NODES" \
      --node-module="node_types/cluster_node.nix" \
      --service-group="backends" \
      --ctrl-nodes="$CTRL_NODES"

  sleep 2 # allow cluster to settle

  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$SERVICE_NODES $OTHER_NODES" "nixos-rebuild switch --fast"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$SERVICE_NODES $OTHER_NODES" "systemctl restart confd"

  _init_nodes=`date +%s`

  # Verify the operation of the test cluster
  echo "******************************************"
  testCluster
  echo "******************************************"

  _end=`date +%s`

  if [[ "$TEARDOWN" != "no" ]]; then
    tearDownCluster
  fi

  _after_teardown=`date +%s`

  echo "            **              **            "
  echo "            **              **            "
  echo "******************************************"

  printTime() {
    local _start=$1; local _end=$2; local _secs=$((_end-_start))
    printf '%02dh:%02dm:%02ds' $(($_secs/3600)) $(($_secs%3600/60)) $(($_secs%60))
  }
  printf '+ provision  %s\n' $(printTime $_start $_provision)
  printf '+ init       %s\n' $(printTime $_provision $_init_nodes)
  printf '+ test       %s\n' $(printTime $_init_nodes $_end)
  printf '= SUM %s\n' $(printTime $_start $_end)
  echo "***************** DONE *******************"
fi