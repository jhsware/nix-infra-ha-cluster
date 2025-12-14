#!/usr/bin/env bash
# KeyDB HA cluster test for nix-infra-ha-cluster
#
# This test:
# 1. Deploys KeyDB HA cluster on service nodes
# 2. Deploys a test app on worker nodes that uses KeyDB
# 3. Verifies the services are running
# 4. Tests KeyDB cluster and basic operations
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

if [ "$CMD" = "publish" ]; then
  echo "Publishing applications..."
  publishImageToRegistry app-redis-pod "$WORK_DIR/app_images/app-redis-pod.tar.gz" "1.0"
  return 0
fi

if [ "$CMD" = "teardown" ]; then
  echo "Tearing down KeyDB test..."
  
  # Stop KeyDB services
  echo "  Stopping KeyDB services..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" \
    'systemctl stop podman-keydb-ha 2>/dev/null || true'
  
  # Remove KeyDB data files
  echo "  Removing KeyDB data files..."
  _cmd_='if ! systemctl cat podman-keydb-ha.service &>/dev/null; then rm -rf /var/lib/keydb-ha; fi'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" "$_cmd_"
  
  # Stop app container on worker nodes
  echo "  Stopping app services..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" \
    'systemctl stop podman-app-redis-pod 2>/dev/null || true'
  
  # Remove OCI images
  echo "  Removing OCI images..."
  _cmd_='podman stop $(podman ps -aq) 2>/dev/null; podman rm $(podman ps -aq) 2>/dev/null; podman rmi -f $(podman images -aq) 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"

  # Remove Systemd credentials
  echo "  Removing Systemd credentials..."
  _cmd_="rm -rf /run/credentials/* 2>/dev/null || true; rm -rf /run/systemd/credentials/* 2>/dev/null || true"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"
  
  echo "KeyDB teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "KeyDB HA Cluster Test"
echo "========================================"
echo ""

# Store connection string secret
echo "Step 1: Storing connection string secret..."
$NIX_INFRA secrets store -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
  --secret="redis://default:SUPER_SECRET_PASSWORD@[%%service001.overlayIp%%]:6380" \
  --name="keydb.connectionString"

# Deploy the KeyDB configuration to all nodes
echo ""
echo "Step 2: Deploying KeyDB configuration..."
$NIX_INFRA cluster deploy-apps -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$SERVICE_NODES $OTHER_NODES"

# ============================================================================
# KeyDB Cluster Setup
# ============================================================================

echo ""
echo "Step 3: Configuring KeyDB cluster nodes..."
echo ""

# Apply updated configuration sequentially to allow cluster to form properly
for node in service001 service002 service003; do
  echo "  Configuring $node..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$node" "nixos-rebuild switch --fast"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$node" "systemctl restart confd"
done

# Apply the update to the worker node(s)
echo "  Configuring worker nodes..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "systemctl restart confd"

# Publish app image (this takes a while and allows DBs to form clusters during upload)
echo ""
echo "Step 4: Publishing app image to registry..."
publishImageToRegistry app-redis-pod "$WORK_DIR/app_images/app-redis-pod.tar.gz" "1.0"

# Restart service now that the image has been uploaded
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "systemctl restart podman-app-redis-pod"

# Wait for KeyDB to accept initialization
echo ""
echo "  Waiting for app to initialize..."
for i in {1..30}; do
  result=$($NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "curl --max-time 2 -s http://127.0.0.1:11411/init")
  if [[ "$result" == *"init"* ]]; then
    echo -e "  ${GREEN}✓${NC} App initialized on attempt $i [pass]"
    break
  fi
  printf "."
    
  if [ $i -eq 30 ]; then
    echo -e "\n  ${RED}✗${NC} Couldn't initialize app [fail]"
    $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "journalctl -n 30 -u podman-app-redis-pod"
    exit 1
  fi
  sleep 1
done

_setup=$(date +%s)

# ============================================================================
# Test Verification
# ============================================================================

echo ""
echo "Step 5: Verifying KeyDB deployment..."
echo ""

# Check if the systemd service is active on service nodes
echo "Checking systemd service status..."
for node in service001 service002 service003; do
  service_status=$(cmd "$node" "systemctl is-active podman-keydb-ha")
  if [[ "$service_status" == *"active"* ]]; then
    echo -e "  ${GREEN}✓${NC} podman-keydb-ha: active ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} podman-keydb-ha: $service_status ($node) [fail]"
    echo ""
    echo "Service logs:"
    cmd "$node" "journalctl -n 30 -u podman-keydb-ha"
  fi
done

# Check if containers are running
echo ""
echo "Checking container status..."
for node in service001 service002 service003; do
  container_status=$(cmd "$node" "podman ps --filter name=keydb-ha --format '{{.Names}} {{.Status}}'")
  if [[ "$container_status" == *"keydb-ha"* ]]; then
    echo -e "  ${GREEN}✓${NC} Container running: $container_status ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} Container not running ($node) [fail]"
    echo "All containers:"
    cmd "$node" "podman ps -a"
  fi
done

# Check if KeyDB port is listening
echo ""
echo "Checking KeyDB port (6380)..."
for node in service001 service002 service003; do
  port_check=$(cmd "$node" "ss -tlnp | grep 6380")
  if [[ "$port_check" == *"6380"* ]]; then
    echo -e "  ${GREEN}✓${NC} Port 6380 is listening ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} Port 6380 is not listening ($node) [fail]"
  fi
done

# ============================================================================
# App Tests
# ============================================================================

echo ""
echo "Step 6: Testing app functionality..."
echo ""

# Check that app is running
echo "Checking app service status..."
app_status=$(cmd "worker001" "systemctl is-active podman-app-redis-pod.service")
if [[ "$app_status" == *"active"* ]]; then
  echo -e "  ${GREEN}✓${NC} podman-app-redis-pod: active (worker001) [pass]"
else
  echo -e "  ${RED}✗${NC} podman-app-redis-pod: $app_status (worker001) [fail]"
fi

# Check that app responds locally
echo ""
echo "Checking app responds to ping..."
ping_result=$(cmd "worker001" "curl -s http://\$(ifconfig flannel-wg | grep inet | awk '\$1==\"inet\" {print \$2}'):11411/ping")
if [[ "$ping_result" == *"pong"* ]]; then
  echo -e "  ${GREEN}✓${NC} App responds to ping (worker001) [pass]"
else
  echo -e "  ${RED}✗${NC} App ping failed: $ping_result (worker001) [fail]"
fi

# Test app database operations
echo ""
echo "Testing app database operations..."

# Insert test record
echo "  Inserting test record..."
result1=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11411/db?id=1&message=hello'")
if [[ "$result1" == *"1"* ]]; then
  echo -e "  ${GREEN}✓${NC} Insert record 1 successful [pass]"
else
  echo -e "  ${RED}✗${NC} Insert record 1 failed: $result1 [fail]"
fi

# Query test record
echo "  Querying test record..."
query1=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11411/db/1")
if [[ "$query1" == *"hello"* ]]; then
  echo -e "  ${GREEN}✓${NC} Query record 1: hello [pass]"
else
  echo -e "  ${RED}✗${NC} Query record 1 failed: $query1 [fail]"
fi

# Additional insert/query tests
echo "  Inserting additional test records..."
result2=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11411/db?id=2&message=world'")
result3=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11411/db?id=3&message=test'")

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

echo "  Querying additional test records..."
query2=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11411/db/2")
query3=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11411/db/3")

if [[ "$query2" == *"world"* ]]; then
  echo -e "  ${GREEN}✓${NC} Query record 2: world [pass]"
else
  echo -e "  ${RED}✗${NC} Query record 2 failed: $query2 [fail]"
fi

if [[ "$query3" == *"test"* ]]; then
  echo -e "  ${GREEN}✓${NC} Query record 3: test [pass]"
else
  echo -e "  ${RED}✗${NC} Query record 3 failed: $query3 [fail]"
fi

# ============================================================================
# KeyDB Action Commands Verification
# ============================================================================

echo ""
echo "Step 7: Verifying KeyDB action commands..."
echo ""

echo "Checking KeyDB status..."
status_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="keydb" --cmd="status")
if [[ -n "$status_result" ]]; then
  echo -e "  ${GREEN}✓${NC} Status command successful [pass]"
else
  echo -e "  ${RED}✗${NC} Status command failed [fail]"
fi

echo "Checking database list..."
dbs_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="keydb" --cmd="dbs")
if [[ -n "$dbs_result" ]]; then
  echo -e "  ${GREEN}✓${NC} Database list command successful [pass]"
else
  echo -e "  ${RED}✗${NC} Database list command failed [fail]"
fi

echo "Checking user list..."
users_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="keydb" --cmd="users")
if [[ -n "$users_result" ]]; then
  echo -e "  ${GREEN}✓${NC} User list command successful [pass]"
else
  echo -e "  ${RED}✗${NC} User list command failed [fail]"
fi

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "KeyDB HA Cluster Test Summary"
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
echo "KeyDB HA Cluster Test Complete"
echo "========================================"
