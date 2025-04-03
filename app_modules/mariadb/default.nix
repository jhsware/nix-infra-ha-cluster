{ config, pkgs, lib, ... }:
let
  appName = "mariadb-cluster";
  appPort = 3306;

  cfg = config.infrastructure.${appName};

  dataDir = "/var/lib/mariadb-cluster";
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -p ${dataDir}
  '';
in
{
  options.infrastructure.${appName} = {
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

    sst = lib.mkOption {
      type = lib.types.int;
      description = "Port for Galera State Snapshot Transfer.";
      default = 4568;
    };

    ist = lib.mkOption {
      type = lib.types.int;
      description = "Port for Galera Incremental State Transfer.";
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
      image = "mariadb:10.11";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:3306"
        "${cfg.bindToIp}:${toString cfg.galeraPort}:4567"
        "${cfg.bindToIp}:${toString cfg.sst}:4568"
        "${cfg.bindToIp}:${toString cfg.ist}:4444"
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
          wsrep_cluster_address="gcomm://${builtins.concatStringsSep "," cfg.nodeAddresses}"

          # Galera Synchronization Configuration
          wsrep_sst_method=rsync

          # Galera Node Configuration
          wsrep_node_address="${cfg.bindToIp}"
          wsrep_node_name="${appName}-${cfg.bindToIp}"
        ''}:/etc/mysql/conf.d/galera.cnf"
      ];
      environment = {
        MARIADB_ROOT_PASSWORD = cfg.rootPassword;
        MARIADB_GALERA_CLUSTER = "ON";
      };

      cmd = [
        "--wsrep-new-cluster"
      ];

      execHooks = {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      };
    };
  };
}