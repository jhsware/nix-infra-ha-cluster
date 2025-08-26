#!/usr/bin/env bash

if [[ "publish update" == *"$1"* ]]; then
  CMD="$1"
  shift
fi

for i in "$@"; do
  case $i in
    --env=*)
    ENV="${i#*=}"
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

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

if [ "$CMD" = "update" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 update --env=$ENV [node1 node2 ...]"
    exit 1
  fi
  (cd "$WORK_DIR" && git fetch origin && git reset --hard origin/$(git branch --show-current))

  # $NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  #   --secret="mysql://root:your-secure-password@[%%service001.overlayIp%%]:3306/test?&connectTimeout=10000&connectionLimit=10&multipleStatements=true" \
  #   --name="mariadb.connectionString"
  #$NIX_INFRA cluster deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" --target="$REST"
  #$NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "nixos-rebuild switch --fast"
  # publishImageToRegistry app-mariadb-pod "$WORK_DIR/app_images/app-mariadb-pod.tar.gz" "1.0"
  # $NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "systemctl restart podman-app-mariadb-pod"
  # $NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=1&message=hello'"
  # sleep 10
  # $NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="status"
  
  #$NIX_INFRA cluster cmd -d $WORK_DIR --target="$REST" "ls /etc/nixos/app_modules"
  # $NIX_INFRA cluster update-node -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  #   --nixos-version=$NIXOS_VERSION \
  #   --node-module="node_types/cluster_node.nix" \
  #   --ctrl-nodes="$CTRL_NODES" \
  #   --target="service001 service002 service003"
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "systemctl restart podman-app-mariadb-pod"
  exit 0
fi

if [ "$CMD" = "publish" ]; then
  echo Publish applications...
  publishImageToRegistry app-mariadb-pod "$WORK_DIR/app_images/app-mariadb-pod.tar.gz" "1.0"
  exit 0
fi


_start=`date +%s`

echo "RUNNING TEST..."
$NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --secret="mysql://root:your-secure-password@[%%service001.overlayIp%%]:3306/test?&connectTimeout=10000&connectionLimit=10&multipleStatements=true" \
  --name="mariadb.connectionString"
  # --secret="mysql://root:your-secure-password@[%%service001.overlayIp%%]:3306,[%%service002.overlayIp%%]:3306,[%%service003.overlayIp%%]:3306/db?&connectTimeout=10000&connectionLimit=10&multipleStatements=true" \

echo "---"

# echo "Are you ready to deploy app nodes proper? (y)"
# read answer

$NIX_INFRA cluster deploy-apps -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$SERVICE_NODES $OTHER_NODES"

# Apply updated configuration sequentially to allow cluster to form properly
$NIX_INFRA cluster cmd -d $WORK_DIR --target="service001" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="service001" "systemctl restart confd"

$NIX_INFRA cluster cmd -d $WORK_DIR --target="service002" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="service002" "systemctl restart confd"

$NIX_INFRA cluster cmd -d $WORK_DIR --target="service003" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="service003" "systemctl restart confd"

# Apply the update work the worker node(s) etc.
$NIX_INFRA cluster cmd -d $WORK_DIR --target="$OTHER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="$OTHER_NODES" "systemctl restart confd"


# This takes a while and allows DBs to form clusters during upload
publishImageToRegistry app-mariadb-pod "$WORK_DIR/app_images/app-mariadb-pod.tar.gz" "1.0"
# Need to restart the service now that the image has been uploaded
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "systemctl restart podman-app-mariadb-pod"

echo -e "\n** MariaDB **"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="create-db --database=hello"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="create-db --database=test"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="create-admin --database=test --username=test-admin"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="create-admin --database=hello --username=hello-admin"

echo "Waiting for MariaDB to accept initialisation:"
for i in {1..10}; do
  result=$($NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/init") # > init
  if [[ "$result" == *"init"* ]]; then
      echo -e "\nSuccess! DB initialised on $i attempt(s)."
      break
  fi
  printf "."
    
  if [ $i -eq 30 ]; then
      echo -e "\nCouldn't reach MariaDB"
      $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "journalctl -n 30 -u podman-app-mariadb-pod"
      exit 1
  fi
done

_setup=`date +%s`

# Check that apps are running
echo "Are apps active?"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-mariadb-pod: ";echo -n $(systemctl is-active podman-app-mariadb-pod.service)'
# Check that apps are responding locally
echo "Do apps responds locally?"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-mariadb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11611/ping' # > pong
# Check that app has correct functionality
echo "Do apps function properly?"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=1&message=hello'" # > 1
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=2&message=bye'" # > 2
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=3&message=hello_world'" # > 3

$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/db/1" # > hello
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/db/2" # > bye
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-mariadb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/db/3" # > hello_world

$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="status"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="dbs"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="mariadb" --cmd="users"

$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "journalctl -n 60 -u podman-app-mariadb-pod"

_end=`date +%s`

echo "            **              **            "
echo "            **              **            "
echo "******************************************"

printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $(($_secs/3600)) $(($_secs%3600/60)) $(($_secs%60))
}
printf '+ setup  %s\n' $(printTime $_start $_setup)
printf '+ test  %s\n' $(printTime $_setup $_end)
printf '= SUM %s\n' $(printTime $_start $_end)

echo "***************** DONE *******************"