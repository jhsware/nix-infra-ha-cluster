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
    $NIX_INFRA registry publish-image -d "$WORK_DIR" --batch \
      --target="worker001" \
      --image-name="$IMAGE_NAME" \
      --image-tag="$IMAGE_TAG" \
      --file="$FILE" \
      --use-localhost
}

if [ "$CMD" = "publish" ]; then
  echo Publish applications...
  publishImageToRegistry app-elasticsearch-pod "$WORK_DIR/app_images/app-elasticsearch-pod.tar.gz" "1.0"
  return 0
fi

if [ "$CMD" = "teardown" ]; then
  _cmd_='if ! systemctl cat podman-elasticsearch.service &>/dev/null; then rm -rf "/var/lib/elasticsearch-cluster"; fi'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" "$_cmd_"
  return 0
fi

_start=$(date +%s)

echo "RUNNING TEST..."
$NIX_INFRA secrets store -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
    --secret="http://127.0.0.1:9200" \
    --name="elasticsearch.connectionString"
    # --secret="http://[%%service001.overlayIp%%]:9200,http://[%%service002.overlayIp%%]:9200,http://[%%service003.overlayIp%%]:9200" \

echo "---"

# echo "Are you ready to deploy app nodes proper? (y)"
# read answer

$NIX_INFRA cluster deploy-apps -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$SERVICE_NODES $OTHER_NODES"

# Apply updated configuration sequentially to allow cluster to form properly
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service001" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service001" "systemctl restart confd"

$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service002" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service002" "systemctl restart confd"

$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service003" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service003" "systemctl restart confd"

# Apply the update work the worker node(s) etc.
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "systemctl restart confd"


# This takes a while and allows DBs to form clusters during upload
publishImageToRegistry app-elasticsearch-pod "$WORK_DIR/app_images/app-elasticsearch-pod.tar.gz" "1.0"
# Need to restart the service now that the image has been uploaded
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "systemctl restart podman-app-elasticsearch-pod"

_setup=$(date +%s)

echo -e "\n** Elasticsearch **"

# Check that apps are running
echo "Are apps active?"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" 'printf "app-elasticsearch-pod: ";echo -n $(systemctl is-active podman-app-elasticsearch-pod.service)'

# Check that apps are responding locally

echo "Do apps responds locally?"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" 'printf "app-elasticsearch-pod: "; curl -s http://$(ifconfig flannel-wg | grep inet | awk '\''$1=="inet" {print $2}'\''):11511/ping' # > pong

echo "Do apps function properly?"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "printf 'app-elasticsearch-pod: '; curl --max-time 2 -s 'http://127.0.0.1:11511/db?id=1&message=hello'" # > 1
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "printf 'app-elasticsearch-pod: '; curl --max-time 2 -s http://127.0.0.1:11511/db/1" # > hello

$NIX_INFRA cluster action -d "$WORK_DIR" --target="worker001" --app-module="elasticsearch" --cmd="status"
$NIX_INFRA cluster action -d "$WORK_DIR" --target="worker001" --app-module="elasticsearch" --cmd="apps"
$NIX_INFRA cluster action -d "$WORK_DIR" --target="worker001" --app-module="elasticsearch" --cmd="users"

$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "journalctl -n 60 -u podman-app-elasticsearch-pod"

_end=$(date +%s)

echo "            **              **            "
echo "            **              **            "
echo "******************************************"

printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
}
printf '+ setup  %s\n' $(printTime $_start $_setup)
printf '+ test  %s\n' $(printTime $_setup $_end)
printf '= SUM %s\n' $(printTime $_start $_end)

echo "***************** DONE *******************"