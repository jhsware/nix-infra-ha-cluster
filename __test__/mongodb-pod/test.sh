#!/usr/bin/env bash
# MongoDB HA cluster test for nix-infra-ha-cluster
#
# This test:
# 1. Deploys MongoDB as a podman container on service nodes (replica set)
# 2. Deploys a test app on worker nodes that uses MongoDB
# 3. Verifies the services are running
# 4. Tests MongoDB replica set and basic operations
# 5. Cleans up on teardown

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

cmd() {
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$1" "$2"
}

# Detect which mongo shell is available (mongosh for 5+, mongo for 4.x)
get_mongo_shell() {
  local node=$1
  if cmd "$node" "podman exec mongodb-pod which mongosh" > /dev/null 2>&1; then
    echo "mongosh"
  else
    echo "mongo"
  fi
}

if [ "$CMD" = "publish" ]; then
  echo "Publishing applications..."
  publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz" "1.0"
  return 0
fi

if [ "$CMD" = "teardown" ]; then
  echo "Tearing down MongoDB test..."
  
  # Stop MongoDB services on service nodes
  echo "  Stopping MongoDB services..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" \
    'systemctl stop podman-mongodb-pod 2>/dev/null || true'
  
  # Stop and remove MongoDB containers on service nodes
  echo "  Removing MongoDB containers..."
  _cmd_='podman stop -a 2>/dev/null || true; podman rm -af 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" "$_cmd_"
  
  # Remove MongoDB images on service nodes
  echo "  Removing MongoDB images on service nodes..."
  _cmd_='podman rmi -af 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" "$_cmd_"
  
  # Force remove MongoDB data files
  echo "  Removing MongoDB data files..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" \
    'rm -rf /var/lib/mongodb/*'
  
  # Stop app container on worker nodes
  echo "  Stopping app services..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" \
    'systemctl stop podman-app-mongodb-pod 2>/dev/null || true'
  
  # Stop and remove all containers on worker nodes
  echo "  Removing containers on worker nodes..."
  _cmd_='podman stop -a 2>/dev/null || true; podman rm -af 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"
  
  # Remove all local podman images on worker nodes
  echo "  Removing local podman images..."
  _cmd_='podman rmi -af 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"
  
  # Remove image from docker registry
  echo "  Removing images from registry..."
  _cmd_='curl -s -X DELETE http://127.0.0.1:5000/v2/apps/app-mongodb-pod/manifests/$(curl -s -H "Accept: application/vnd.docker.distribution.manifest.v2+json" http://127.0.0.1:5000/v2/apps/app-mongodb-pod/manifests/latest -I 2>/dev/null | grep -i docker-content-digest | awk "{print \$2}" | tr -d "\r") 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"
  
  # Trigger registry garbage collection
  echo "  Running registry garbage collection..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" \
    'systemctl start docker-registry-garbage-collect 2>/dev/null || true'

  # Remove Systemd credentials
  echo "  Removing Systemd credentials..."
  _cmd_="rm -rf /run/credentials/* 2>/dev/null || true; rm -rf /run/systemd/credentials/* 2>/dev/null || true"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"
  
  echo "MongoDB teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "MongoDB HA Cluster Test (Podman)"
echo "========================================"
echo ""

# Deploy the mongodb configuration to test nodes
echo "Step 1: Deploying MongoDB configuration..."
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

# Apply the update to the worker node(s)
echo "  Configuring worker nodes..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "systemctl restart confd"

# Publish app image (this takes a while and allows DBs to form clusters during upload)
echo ""
echo "Step 3: Publishing app image to registry..."
publishImageToRegistry app-mongodb-pod "$WORK_DIR/app_images/app-mongodb-pod.tar.gz" "1.0"

# Restart service now that the image has been uploaded
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "systemctl restart podman-app-mongodb-pod"

_setup=$(date +%s)

# ============================================================================
# Test Verification
# ============================================================================

echo ""
echo "Step 4: Verifying MongoDB deployment..."
echo ""

# Wait for services to start
echo "Waiting for MongoDB services to start..."
sleep 5

# Check if the systemd service is active on service nodes
echo ""
echo "Checking systemd service status..."
for node in service001 service002 service003; do
  service_status=$(cmd "$node" "systemctl is-active podman-mongodb-pod")
  if [[ "$service_status" == *"active"* ]]; then
    echo -e "  ${GREEN}✓${NC} podman-mongodb-pod: active ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} podman-mongodb-pod: $service_status ($node) [fail]"
    echo ""
    echo "Service logs:"
    cmd "$node" "journalctl -n 30 -u podman-mongodb-pod"
  fi
done

# Check if containers are running
echo ""
echo "Checking container status..."
for node in service001 service002 service003; do
  container_status=$(cmd "$node" "podman ps --filter name=mongodb-pod --format '{{.Names}} {{.Status}}'")
  if [[ "$container_status" == *"mongodb-pod"* ]]; then
    echo -e "  ${GREEN}✓${NC} Container running: $container_status ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} Container not running ($node) [fail]"
    echo "All containers:"
    cmd "$node" "podman ps -a"
  fi
done

# Check if MongoDB port is listening
echo ""
echo "Checking MongoDB port (27017)..."
for node in service001 service002 service003; do
  port_check=$(cmd "$node" "ss -tlnp | grep 27017")
  if [[ "$port_check" == *"27017"* ]]; then
    echo -e "  ${GREEN}✓${NC} Port 27017 is listening ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} Port 27017 is not listening ($node) [fail]"
  fi
done

# Detect mongo shell for direct verification
echo ""
echo "Detecting MongoDB shell..."
MONGO_SHELL=$(get_mongo_shell "service001")
echo "  Using: $MONGO_SHELL"

# ============================================================================
# MongoDB Replica Set Initialization
# ============================================================================

echo ""
echo "Step 5: Initializing MongoDB replica set..."
echo ""

$NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="init" --env-vars="NODE_1=[%%service001.overlayIp%%],NODE_2=[%%service002.overlayIp%%],NODE_3=[%%service003.overlayIp%%]"

# Wait for replica set to initialize and elect primary
echo ""
echo "Waiting for replica set to elect primary..."
rs_status=""
for i in {1..30}; do
  rs_status=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="status")
  if [[ "$rs_status" == *"PRIMARY"* ]]; then
    break
  fi
  echo "  Attempt $i: No primary yet, waiting..."
  sleep 2
done

# Check replica set status
echo ""
echo "Checking replica set status..."
if [[ "$rs_status" == *"PRIMARY"* ]]; then
  echo -e "  ${GREEN}✓${NC} Replica set has a PRIMARY member [pass]"
else
  echo -e "  ${RED}✗${NC} Replica set PRIMARY not found [fail]"
fi

# Direct verification using detected shell
echo ""
echo "Direct verification of replica set members..."
for node in service001 service002 service003; do
  member_state=$(cmd "$node" "podman exec mongodb-pod $MONGO_SHELL --host 127.0.0.1 --port 27017 --quiet --eval 'rs.status().myState'")
  if [[ "$member_state" == "1" ]]; then
    echo -e "  ${GREEN}✓${NC} $node is PRIMARY (state=$member_state) [pass]"
  elif [[ "$member_state" == "2" ]]; then
    echo -e "  ${GREEN}✓${NC} $node is SECONDARY (state=$member_state) [pass]"
  else
    echo -e "  ${RED}✗${NC} $node has unexpected state: $member_state [fail]"
  fi
done

# ============================================================================
# Database and User Setup
# ============================================================================

echo ""
echo "Step 6: Creating databases and users..."
echo ""

echo "  Creating database 'hello'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-db --database=hello")
if [[ "$result" == *"mongodb://"* ]]; then
  echo -e "  ${GREEN}✓${NC} Database 'hello' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create database 'hello': $result [fail]"
fi

echo "  Creating database 'foo'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-db --database=foo")
if [[ "$result" == *"mongodb://"* ]]; then
  echo -e "  ${GREEN}✓${NC} Database 'foo' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create database 'foo': $result [fail]"
fi

echo "  Creating admin user for 'foo'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-admin --database=foo --username=foo-admin")
if [[ "$result" == *"mongodb://"* ]]; then
  echo -e "  ${GREEN}✓${NC} Admin user 'foo-admin' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create admin user: $result [fail]"
fi

echo "  Creating admin user for 'hello'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="create-admin --database=hello --username=hello-admin")
if [[ "$result" == *"mongodb://"* ]]; then
  echo -e "  ${GREEN}✓${NC} Admin user 'hello-admin' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create admin user: $result [fail]"
fi

# ============================================================================
# App Tests
# ============================================================================

echo ""
echo "Step 7: Testing app functionality..."
echo ""

# Check that app is running
echo "Checking app service status..."
app_status=$(cmd "worker001" "systemctl is-active podman-app-mongodb-pod.service")
if [[ "$app_status" == *"active"* ]]; then
  echo -e "  ${GREEN}✓${NC} podman-app-mongodb-pod: active (worker001) [pass]"
else
  echo -e "  ${RED}✗${NC} podman-app-mongodb-pod: $app_status (worker001) [fail]"
fi

# Check that app responds locally
echo ""
echo "Checking app responds to ping..."
ping_result=$(cmd "worker001" "curl -s http://\$(ifconfig flannel-wg | grep inet | awk '\$1==\"inet\" {print \$2}'):11311/ping")
if [[ "$ping_result" == *"pong"* ]]; then
  echo -e "  ${GREEN}✓${NC} App responds to ping (worker001) [pass]"
else
  echo -e "  ${RED}✗${NC} App ping failed: $ping_result (worker001) [fail]"
fi

# Test app database operations
echo ""
echo "Testing app database operations..."

# Insert test records
echo "  Inserting test records..."
result1=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=1&message=hello'")
result2=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=2&message=bye'")
result3=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11311/db?id=3&message=hello_world'")

if [[ "$result1" == *"1"* ]]; then
  echo -e "  ${GREEN}✓${NC} Insert record 1 successful [pass]"
else
  echo -e "  ${RED}✗${NC} Insert record 1 failed: $result1 [fail]"
fi

if [[ "$result2" == *"2"* ]]; then
  echo -e "  ${GREEN}✓${NC} Insert record 2 successful [pass]"
else
  echo -e "  ${RED}✗${NC} Insert record 2 failed: $result2 [fail]"
fi

if [[ "$result3" == *"3"* ]]; then
  echo -e "  ${GREEN}✓${NC} Insert record 3 successful [pass]"
else
  echo -e "  ${RED}✗${NC} Insert record 3 failed: $result3 [fail]"
fi

# Query test records
echo "  Querying test records..."
query1=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11311/db/1")
query2=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11311/db/2")
query3=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11311/db/3")

if [[ "$query1" == *"hello"* ]]; then
  echo -e "  ${GREEN}✓${NC} Query record 1: hello [pass]"
else
  echo -e "  ${RED}✗${NC} Query record 1 failed: $query1 [fail]"
fi

if [[ "$query2" == *"bye"* ]]; then
  echo -e "  ${GREEN}✓${NC} Query record 2: bye [pass]"
else
  echo -e "  ${RED}✗${NC} Query record 2 failed: $query2 [fail]"
fi

if [[ "$query3" == *"hello_world"* ]]; then
  echo -e "  ${GREEN}✓${NC} Query record 3: hello_world [pass]"
else
  echo -e "  ${RED}✗${NC} Query record 3 failed: $query3 [fail]"
fi

# ============================================================================
# MongoDB Action Commands Verification
# ============================================================================

echo ""
echo "Step 8: Verifying MongoDB action commands..."
echo ""

echo "Checking database list..."
dbs_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="dbs")
if [[ "$dbs_result" == *"hello"* ]] && [[ "$dbs_result" == *"foo"* ]]; then
  echo -e "  ${GREEN}✓${NC} Database list shows 'hello' and 'foo' [pass]"
else
  echo -e "  ${RED}✗${NC} Database list incomplete: $dbs_result [fail]"
fi

echo "Checking user list..."
users_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mongodb-pod" --cmd="users")
if [[ "$users_result" == *"foo-admin"* ]] && [[ "$users_result" == *"hello-admin"* ]]; then
  echo -e "  ${GREEN}✓${NC} User list shows admin users [pass]"
else
  echo -e "  ${RED}✗${NC} User list incomplete: $users_result [fail]"
fi

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "MongoDB HA Cluster Test Summary"
echo "========================================"

printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
}

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "MongoDB HA Cluster Test Complete"
echo "========================================"
