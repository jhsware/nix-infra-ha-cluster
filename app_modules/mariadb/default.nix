{ config, pkgs, lib, ... }:

let
  appName = "mariadb-cluster";
  appPort = 3306;

  cfg = config.infrastructure.${appName};

  primaryAddress = builtins.elemAt cfg.nodeAddresses 0;
  isPrimaryNode = cfg.bindToIp == (builtins.elemAt cfg.nodeAddresses 0);
  primaryHost = builtins.head (builtins.split ":" primaryAddress);

  dataDir = "/var/lib/mysql";

  queryPrimaryCmd = ''
    ${pkgs.mariadb}/bin/mysql -h ${primaryHost} -P ${toString cfg.bindToPort} \
         -u root -p${cfg.rootPassword}'';

  checkPrimaryScript = pkgs.writeShellScript "check-primary" ''
    echo "Wait for 15 sec before probing primary"
    sleep 15
    RETRIES=60
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

    nodeName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the Galera cluster node.";
    };

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
      package = pkgs.mariadb;  # Regular mariadb package includes Galera

      galeraCluster = {
        enable = true;
        package = pkgs.mariadb-galera;
        sstMethod = "mariabackup";
        nodeAddresses = cfg.nodeAddresses;
        name = cfg.clusterName;
        localName = cfg.nodeName;
        localAddress = cfg.bindToIp;
        #clusterPassword = "";
      };
    };
  };
}