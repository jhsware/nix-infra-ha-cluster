{ config, pkgs, lib, ... }:

let
  appName = "mariadb-cluster";
  appPort = 3306;

  cfg = config.infrastructure.${appName};

  primaryAddress = builtins.elemAt cfg.nodeAddresses 0;
  isPrimaryNode = cfg.bindToIp == (builtins.elemAt cfg.nodeAddresses 0);
  # Extract just the host part if the address includes a port
  primaryHost = builtins.head (builtins.split ":" primaryAddress);

  dataDir = "/var/lib/mysql";

  queryPrimaryCmd = ''
    ${pkgs.mariadb}/bin/mysql -h ${primaryHost} -P ${toString cfg.bindToPort} \
         -u root -p${cfg.rootPassword}'';

  checkPrimaryScript = pkgs.writeShellScript "check-primary" ''
    echo "Wait for 15 sec before probing primary"
    sleep 15
    RETRIES=36 # 5 x 36 = 3 mins
    while [ $RETRIES -gt 0 ]; do
      if ${queryPrimaryCmd} -e "SHOW STATUS LIKE 'wsrep_cluster_status'" 2>/dev/null | grep -q "Primary"; then
        echo "MariaDB cluster primary node detected and available (wsrep_cluster_status = Primary)"
        if ${queryPrimaryCmd} -e "SHOW STATUS LIKE 'wsrep_ready'" 2>/dev/null | grep -q "ON"; then
          echo "MariaDB cluster primary node ready (wsrep_ready = ON)"
          echo "Wait for 5 sec before starting secondary"
          sleep 5
          exit 0
        fi
      fi
      echo "Primary node not ready yet, waiting..."
      sleep 5
      RETRIES=$((RETRIES-1))
    done
    echo "Timeout waiting for primary node"
    exit 1
  '';
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.mariadb-cluster";

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the Galera cluster.";
      default = "mariadb_cluster";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind.";
      default = "0.0.0.0";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port to bind.";
      default = appPort;
    };

    galeraPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for Galera cluster communication.";
      default = 4567;
    };

    ist = lib.mkOption {
      type = lib.types.int;
      description = "Port for Galera Incremental State Transfer.";
      default = 4568;
    };

    sst = lib.mkOption {
      type = lib.types.int;
      description = "Port for Galera State Snapshot Transfer.";
      default = 4444;
    };

    nodeAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "List of cluster node addresses (IP or IP:port).";
      default = [];
      example = [ "192.168.1.10" "192.168.1.11" ];
    };

    rootPassword = lib.mkOption {
      type = lib.types.str;
      description = "MariaDB root password.";
      default = "";
    };
  };

  config = lib.mkIf cfg.enable {
    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      
      settings = {
        mysqld = {
          # Basic configuration
          port = cfg.bindToPort;
          bind-address = cfg.bindToIp;
          datadir = dataDir;
          
          # InnoDB settings for Galera
          binlog_format = "ROW";
          default-storage-engine = "innodb";
          innodb_autoinc_lock_mode = 2;
          innodb_flush_log_at_trx_commit = 0;
          
          # Galera Provider Configuration
          wsrep_on = "ON";
          wsrep_provider = "${pkgs.mariadb}/lib/galera/libgalera_smm.so";
          
          # Galera Cluster Configuration
          wsrep_cluster_name = cfg.clusterName;
          wsrep_cluster_address = "gcomm://${builtins.concatStringsSep "," cfg.nodeAddresses}";
          
          # Galera Synchronization Configuration
          wsrep_sst_method = "mariabackup";
          wsrep_sst_auth = "root:${cfg.rootPassword}";
          
          # Galera Node Configuration
          wsrep_node_address = cfg.bindToIp;
          wsrep_node_name = "${appName}-${cfg.bindToIp}";
          
          # Performance settings
          wsrep_slave_threads = 4;
        };
      };

      initialScript = pkgs.writeText "mysql-init.sql" ''
        -- Ensure root password is set
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${cfg.rootPassword}';
        -- Allow root from any host (for cluster management)
        CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${cfg.rootPassword}';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
      '';
    };

    # systemd service customization for Galera
    systemd.services.mysql = {
      # Pre-start script to clean up stale SST files
      preStart = lib.mkBefore ''
        # Clean up stale SST files if they exist
        rm -f ${dataDir}/rsync_sst* ${dataDir}/sst_in_progress ${dataDir}/wsrep_sst.pid
        # Kill any stale SST processes
        ${pkgs.procps}/bin/pkill -f wsrep_sst || true
        
        ${lib.optionalString (!isPrimaryNode) ''
          # Wait for primary node to be ready (only on secondary nodes)
          ${checkPrimaryScript}
        ''}
      '';
      
      # Restart policy
      restartIfChanged = false;
      reloadIfChanged = true;
    };

    # Required packages for Galera mariabackup SST
    environment.systemPackages = with pkgs; [
      socat
      mariadb
    ];

    # Firewall rules for Galera cluster communication
    networking.firewall = lib.mkIf config.networking.firewall.enable {
      allowedTCPPorts = [
        cfg.bindToPort      # MySQL
        cfg.galeraPort      # Galera replication
        cfg.ist             # Incremental State Transfer
        cfg.sst             # State Snapshot Transfer
      ];
    };
  };
}