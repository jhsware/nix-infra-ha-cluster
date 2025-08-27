#!/usr/bin/env bash

if [[ "publish teardown" == *"$1"* ]]; then
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

if [ "$CMD" = "publish" ]; then
  echo Publish applications...
  publishImageToRegistry app-redis-pod "$WORK_DIR/app_images/app-redis-pod.tar.gz" "1.0"
  exit 0
fi

if [ "$CMD" = "teardown" ]; then
  local _cmd_ = 'if ! systemctl cat podman-keydb-ha.service &>/dev/null; then rm -rf "/var/lib/keydb-ha"; fi'
  $NIX_INFRA cluster cmd -d $WORK_DIR --target="$SERVICE_NODES" "$_cmd_"
  exit 0
fi

_start=`date +%s`

echo "RUNNING TEST..."
$NIX_INFRA secrets store -d $WORK_DIR --batch --env="$WORK_DIR/.env" \
  --secret="redis://default:SUPER_SECRET_PASSWORD@[%%service001.overlayIp%%]:6380" \
  --name="keydb.connectionString"
  # --secret="redis://default:SUPER_SECRET_PASSWORD@127.0.0.1:6380" \

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
publishImageToRegistry app-redis-pod "$WORK_DIR/app_images/app-redis-pod.tar.gz" "1.0"
# Need to restart the service now that the image has been uploaded
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "systemctl restart podman-app-redis-pod"

echo -e "\n** KeyDB **"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-redis-pod: ";echo -n $(systemctl is-active podman-app-redis-pod.service)'

echo "Waiting for KeyDB to accept initialisation:"
for i in {1..10}; do
  result=$($NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-keydb-pod: '; curl --max-time 2 -s http://127.0.0.1:11611/init") # > init
  if [[ "$result" == *"init"* ]]; then
      echo -e "\nSuccess! DB initialised on $i attempt(s)."
      break
  fi
  printf "."
    
  if [ $i -eq 30 ]; then
      echo -e "\nCouldn't reach KeyDB"
      $NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "journalctl -n 30 -u podman-app-redis-pod"
      exit 1
  fi
done

_setup=`date +%s`

# Check that apps are running
echo "Are apps active?"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-keydb-pod: ";echo -n $(systemctl is-active podman-app-redis-pod.service)'
# Check that apps are responding locally

echo "Do apps responds locally?"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" 'printf "app-keydb-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11411/ping' # > pong# Check that app has correct functionality

echo "Do apps function properly?"
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-keydb-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11411/db?id=1&message=hello'" # > 1
$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "printf 'app-redis-pod: '; curl --max-time 2 -s http://127.0.0.1:11411/db/1" # > hello

$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="keydb" --cmd="status"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="keydb" --cmd="dbs"
$NIX_INFRA cluster action -d $WORK_DIR --target="service001" --app-module="keydb" --cmd="users"

$NIX_INFRA cluster cmd -d $WORK_DIR --target="worker001" "journalctl -n 60 -u podman-app-redis-pod"

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