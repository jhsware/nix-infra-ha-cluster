#!/usr/bin/env bash
# MariaDB Galera cluster test for nix-infra-ha-cluster
#
# This test:
# 1. Deploys MariaDB Galera cluster on service nodes
# 2. Deploys a test app on worker nodes that uses MariaDB
# 3. Verifies the services are running
# 4. Tests MariaDB cluster and basic operations
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

if [ "$CMD" = "publish" ]; then
  echo "Publishing applications..."
  publishImageToRegistry app-mariadb-pod "$WORK_DIR/app_images/app-mariadb-pod.tar.gz" "1.0"
  return 0
fi

if [ "$CMD" = "teardown" ]; then
  echo "Tearing down MariaDB test..."
  
  # Stop MariaDB services
  echo "  Stopping MariaDB services..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" \
    'systemctl stop mysql 2>/dev/null || true'
  
  # Remove MariaDB data files
  echo "  Removing MariaDB data files..."
  _cmd_='if ! systemctl cat podman-mariadb-cluster.service &>/dev/null; then rm -rf /etc/my.cnf /var/lib/mysql /var/run/mysqld; fi'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$SERVICE_NODES" "$_cmd_"
  
  # Stop app container on worker nodes
  echo "  Stopping app services..."
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" \
    'systemctl stop podman-app-mariadb-pod 2>/dev/null || true'
  
  # Remove OCI images
  echo "  Removing OCI images..."
  _cmd_='podman stop $(podman ps -aq) 2>/dev/null; podman rm $(podman ps -aq) 2>/dev/null; podman rmi -f $(podman images -aq) 2>/dev/null || true'
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"

  # Remove Systemd credentials
  echo "  Removing Systemd credentials..."
  _cmd_="rm -rf /run/credentials/* 2>/dev/null || true; rm -rf /run/systemd/credentials/* 2>/dev/null || true"
  $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "$_cmd_"
  
  echo "MariaDB teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "MariaDB Galera Cluster Test"
echo "========================================"
echo ""

# Store connection string secret
echo "Step 1: Storing connection string secret..."
$NIX_INFRA secrets store -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
  --secret="mysql://test-admin:your-secure-password@[%%service001.overlayIp%%]:3306,[%%service002.overlayIp%%]:3306,[%%service003.overlayIp%%]:3306/db?&connectTimeout=10000&connectionLimit=10&multipleStatements=true" \
  --name="mariadb.connectionString"

# Deploy the MariaDB configuration to service nodes
echo ""
echo "Step 2: Deploying MariaDB configuration..."
$NIX_INFRA cluster deploy-apps -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$SERVICE_NODES"

# ============================================================================
# Galera Cluster Bootstrap
# ============================================================================

echo ""
echo "Step 3: Bootstrapping Galera cluster..."
echo ""

# Configure and bootstrap first node
echo "  Configuring service001 (bootstrap node)..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service001" "nixos-rebuild switch --fast; systemctl stop mysql; systemctl restart confd"

echo "  Starting Galera cluster..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service001" "galera_new_cluster; systemctl start mysql; systemctl status mysql"

# Check cluster size on first node
cluster_size=$(cmd "service001" "mysql -N -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\" | awk '{print \$2}'")
if [[ "$cluster_size" -ge 1 ]]; then
  echo -e "  ${GREEN}✓${NC} Cluster bootstrapped, size: $cluster_size [pass]"
else
  echo -e "  ${RED}✗${NC} Cluster bootstrap failed [fail]"
fi

# Create SST user on first node
echo "  Creating SST replication user..."
$NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="create-sst-user --username=check_repl --password=check_pass" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password"

# Join second node
echo ""
echo "  Joining service002 to cluster..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service002" "nixos-rebuild switch --fast; systemctl stop mysql; systemctl restart confd; systemctl start mysql"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service002" "mysql -e \"
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'check_repl'@'localhost';
FLUSH PRIVILEGES;
\""

cluster_size=$(cmd "service002" "mysql -N -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\" | awk '{print \$2}'")
if [[ "$cluster_size" -ge 2 ]]; then
  echo -e "  ${GREEN}✓${NC} service002 joined cluster, size: $cluster_size [pass]"
else
  echo -e "  ${RED}✗${NC} service002 failed to join cluster [fail]"
fi

# Join third node
echo ""
echo "  Joining service003 to cluster..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service003" "nixos-rebuild switch --fast; systemctl stop mysql; systemctl restart confd; systemctl start mysql"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="service003" "mysql -e \"
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'check_repl'@'localhost';
FLUSH PRIVILEGES;
\""

cluster_size=$(cmd "service003" "mysql -N -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\" | awk '{print \$2}'")
if [[ "$cluster_size" -ge 3 ]]; then
  echo -e "  ${GREEN}✓${NC} service003 joined cluster, size: $cluster_size [pass]"
else
  echo -e "  ${RED}✗${NC} service003 failed to join cluster [fail]"
fi

# ============================================================================
# Database and User Setup
# ============================================================================

echo ""
echo "Step 4: Creating databases and users..."
echo ""

echo "  Creating database 'hello'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="create-db --database=hello" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password")
if [[ "$result" == *"mysql://"* ]] || [[ "$result" == *"created"* ]]; then
  echo -e "  ${GREEN}✓${NC} Database 'hello' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create database 'hello': $result [fail]"
fi

echo "  Creating database 'test'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="create-db --database=test" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password")
if [[ "$result" == *"mysql://"* ]] || [[ "$result" == *"created"* ]]; then
  echo -e "  ${GREEN}✓${NC} Database 'test' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create database 'test': $result [fail]"
fi

echo "  Creating admin user for 'test'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="create-admin --database=test --username=test-admin" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password" --save-as-secret="mariadb.test-admin.connectionString")
if [[ "$result" == *"mysql://"* ]]; then
  echo -e "  ${GREEN}✓${NC} Admin user 'test-admin' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create admin user: $result [fail]"
fi

echo "  Creating admin user for 'hello'..."
result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="create-admin --database=hello --username=hello-admin" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password" --save-as-secret="mariadb.hello-admin.connectionString")
if [[ "$result" == *"mysql://"* ]]; then
  echo -e "  ${GREEN}✓${NC} Admin user 'hello-admin' created [pass]"
else
  echo -e "  ${RED}✗${NC} Failed to create admin user: $result [fail]"
fi

# ============================================================================
# Worker Node Setup
# ============================================================================

echo ""
echo "Step 5: Setting up worker nodes..."
echo ""

# Deploy the apps on workers now that the secrets have been created
echo "  Deploying apps to worker nodes..."
$NIX_INFRA cluster deploy-apps -d "$WORK_DIR" --batch --env="$WORK_DIR/.env" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$OTHER_NODES"

# Apply the update to the worker node(s)
echo "  Applying NixOS configuration..."
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "nixos-rebuild switch --fast"
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="$OTHER_NODES" "systemctl restart confd"

# Publish app image
echo ""
echo "Step 6: Publishing app image to registry..."
publishImageToRegistry app-mariadb-pod "$WORK_DIR/app_images/app-mariadb-pod.tar.gz" "1.0"

# Restart service now that the image has been uploaded
$NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "systemctl restart podman-app-mariadb-pod"

# Wait for MariaDB to accept initialization
echo ""
echo "  Waiting for app to initialize database..."
for i in {1..30}; do
  result=$($NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "curl --max-time 2 -s http://127.0.0.1:11611/init")
  if [[ "$result" == *"init"* ]]; then
    echo -e "  ${GREEN}✓${NC} Database initialized on attempt $i [pass]"
    break
  fi
  printf "."
    
  if [ $i -eq 30 ]; then
    echo -e "\n  ${RED}✗${NC} Couldn't initialize database [fail]"
    $NIX_INFRA cluster cmd -d "$WORK_DIR" --target="worker001" "journalctl -n 30 -u podman-app-mariadb-pod"
    exit 1
  fi
  sleep 1
done

_setup=$(date +%s)

# ============================================================================
# Test Verification
# ============================================================================

echo ""
echo "Step 7: Verifying MariaDB deployment..."
echo ""

# Check MySQL service status on all nodes
echo "Checking MySQL service status..."
for node in service001 service002 service003; do
  service_status=$(cmd "$node" "systemctl is-active mysql")
  if [[ "$service_status" == *"active"* ]]; then
    echo -e "  ${GREEN}✓${NC} mysql: active ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} mysql: $service_status ($node) [fail]"
  fi
done

# Check cluster size
echo ""
echo "Checking Galera cluster size..."
for node in service001 service002 service003; do
  cluster_size=$(cmd "$node" "mysql -N -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\" | awk '{print \$2}'")
  if [[ "$cluster_size" -eq 3 ]]; then
    echo -e "  ${GREEN}✓${NC} Cluster size: $cluster_size ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} Cluster size: $cluster_size ($node) [fail]"
  fi
done

# Check MySQL port is listening
echo ""
echo "Checking MySQL port (3306)..."
for node in service001 service002 service003; do
  port_check=$(cmd "$node" "ss -tlnp | grep 3306")
  if [[ "$port_check" == *"3306"* ]]; then
    echo -e "  ${GREEN}✓${NC} Port 3306 is listening ($node) [pass]"
  else
    echo -e "  ${RED}✗${NC} Port 3306 is not listening ($node) [fail]"
  fi
done

# ============================================================================
# App Tests
# ============================================================================

echo ""
echo "Step 8: Testing app functionality..."
echo ""

# Check that app is running
echo "Checking app service status..."
app_status=$(cmd "worker001" "systemctl is-active podman-app-mariadb-pod.service")
if [[ "$app_status" == *"active"* ]]; then
  echo -e "  ${GREEN}✓${NC} podman-app-mariadb-pod: active (worker001) [pass]"
else
  echo -e "  ${RED}✗${NC} podman-app-mariadb-pod: $app_status (worker001) [fail]"
fi

# Check that app responds locally
echo ""
echo "Checking app responds to ping..."
ping_result=$(cmd "worker001" "curl -s http://\$(ifconfig flannel-wg | grep inet | awk '\$1==\"inet\" {print \$2}'):11611/ping")
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
result1=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=1&message=hello'")
result2=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=2&message=bye'")
result3=$(cmd "worker001" "curl --max-time 2 -s 'http://127.0.0.1:11611/db?id=3&message=hello_world'")

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
query1=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11611/db/1")
query2=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11611/db/2")
query3=$(cmd "worker001" "curl --max-time 2 -s http://127.0.0.1:11611/db/3")

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
# MariaDB Action Commands Verification
# ============================================================================

echo ""
echo "Step 9: Verifying MariaDB action commands..."
echo ""

echo "Checking cluster status..."
status_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="status" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password")
if [[ "$status_result" == *"wsrep"* ]] || [[ "$status_result" == *"Primary"* ]]; then
  echo -e "  ${GREEN}✓${NC} Cluster status check successful [pass]"
else
  echo -e "  ${RED}✗${NC} Cluster status check failed [fail]"
fi

echo "Checking database list..."
dbs_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="dbs" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password")
if [[ "$dbs_result" == *"hello"* ]] && [[ "$dbs_result" == *"test"* ]]; then
  echo -e "  ${GREEN}✓${NC} Database list shows 'hello' and 'test' [pass]"
else
  echo -e "  ${RED}✗${NC} Database list incomplete: $dbs_result [fail]"
fi

echo "Checking user list..."
users_result=$($NIX_INFRA cluster action -d "$WORK_DIR" --target="service001" --app-module="mariadb" --cmd="users" --env-vars="MARIADB_ROOT_PASSWORD=your-secure-password")
if [[ "$users_result" == *"test-admin"* ]] && [[ "$users_result" == *"hello-admin"* ]]; then
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
echo "MariaDB Galera Cluster Test Summary"
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
echo "MariaDB Galera Cluster Test Complete"
echo "========================================"
