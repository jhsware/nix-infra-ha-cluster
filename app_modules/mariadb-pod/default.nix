{ config, pkgs, lib, ... }:
let
  appName = "mariadb-cluster-pod";
  appPort = 3306;

  cfg = config.infrastructure.${appName};

  primaryAddress = builtins.elemAt cfg.nodeAddresses 0;
  isPrimaryNode = cfg.bindToIp == (builtins.elemAt cfg.nodeAddresses 0);
  # Extract just the host part if the address includes a port
  primaryHost = builtins.head (builtins.split ":" primaryAddress);

  dataDir = "/var/lib/mariadb-cluster";
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -p ${dataDir}
    # Clean up stale SST files if they exist
    ${pkgs.coreutils}/bin/rm -f ${dataDir}/rsync_sst* ${dataDir}/sst_in_progress ${dataDir}/wsrep_sst.pid
    # Kill any stale SST processes
    ${pkgs.procps}/bin/pkill -f wsrep_sst || true
  '';

  queryPrimaryCmd = ''
    ${pkgs.mariadb}/bin/mysql -h ${primaryHost} -P ${toString cfg.bindToPort} \
         -u root -p${cfg.rootPassword}'';

  checkPrimaryScript = pkgs.writeShellScript "check-primary" ''
    echo "Wait for 15 sec before probing primary"
    sleep 15 # TODO: Make this conditional to first start
    RETRIES=36 # 5 x 36 = 3 mins
    while [ $RETRIES -gt 0 ]; do
      if ${queryPrimaryCmd} -e "SHOW STATUS LIKE 'wsrep_cluster_status'" | grep -q "Primary"; then
        echo "Mariadb cluster primary node detected and available (wsrep_cluster_status = Primary)"
        if ${queryPrimaryCmd} -e "SHOW STATUS LIKE 'wsrep_ready'" | grep -q "ON"; then
          echo "Mariadb cluster primary node ready (wsrep_ready = ON)"
          echo "Wait for 5 sec before starting secondary"
          sleep 5 # TODO: Make this conditional to first start
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
  options.infrastructure."${appName}" = {
    enable = lib.mkEnableOption "infrastructure.mariadb-cluster oci";

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the Galera cluster.";
      default = "mariadb_cluster";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind.";
      default = "127.0.0.1";
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
      description = "List of cluster node addresses (IP:port).";
      default = [];
      example = [ "192.168.1.10:4567" "192.168.1.11:4567" ];
    };

    rootPassword = lib.mkOption {
      type = lib.types.str;
      description = "MariaDB root password.";
      default = "";
    };
  };

  config = lib.mkIf cfg.enable {
    infrastructure.oci-containers.backend = "podman";
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
        serviceGroup = "services";
        protocol = "mysql";
        port = cfg.bindToPort;
        path = "";
        envPrefix = "MARIADB";
      };
      image = "mariadb:11.8";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:3306"
        "${cfg.bindToIp}:${toString cfg.galeraPort}:4567"
        "${cfg.bindToIp}:${toString cfg.ist}:4568"
        "${cfg.bindToIp}:${toString cfg.sst}:4444"
      ];
      bindToIp = cfg.bindToIp;
      volumes = [
        "${dataDir}:/var/lib/mysql"
        "${pkgs.writeText "custom.cnf" ''
          [mysqld]
          binlog_format=ROW
          default-storage-engine=innodb
          innodb_autoinc_lock_mode=2
          bind-address=0.0.0.0

          # Galera Provider Configuration
          wsrep_on=ON
          wsrep_provider=/usr/lib/galera/libgalera_smm.so

          # Galera Cluster Configuration
          wsrep_cluster_name="${cfg.clusterName}"
          wsrep_cluster_address="gcomm://${builtins.concatStringsSep "," (
            builtins.map (ip: "${ip}:${toString cfg.galeraPort}") cfg.nodeAddresses
          )}"

          # Galera Synchronization Configuration
          # - rsync sst is problematic in containerised environments
          wsrep_sst_method=mariadb-backup # requires auth https://mariadb.com/docs/galera-cluster/galera-management/state-snapshot-transfers-ssts-in-galera-cluster/introduction-to-state-snapshot-transfers-ssts#authentication
          wsrep_sst_auth = root:${cfg.rootPassword}

          # Galera Node Configuration
          wsrep_node_address="${cfg.bindToIp}"
          wsrep_node_name="${appName}-${cfg.bindToIp}"
        ''}:/etc/mysql/conf.d/galera.cnf"
      ];
      environment = {
        MARIADB_ROOT_PASSWORD = cfg.rootPassword;
      };

      cmd = if isPrimaryNode then ["--wsrep-new-cluster"] else [];

      execHooks = if isPrimaryNode then {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      } else {
        ExecStartPre = [
          "${execStartPreScript}"
          "${checkPrimaryScript}"
        ];
      };
    };

    # Package required for galera mariabackup option
    environment.systemPackages = with pkgs; [
      socat
    ];
  };
}