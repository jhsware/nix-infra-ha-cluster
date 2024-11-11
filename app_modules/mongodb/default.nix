{ config, pkgs, lib, ... }:
let
  appName = "mongodb-4";
  # appUser = "mongodb";
  appPort = 27017;

  cfg = config.infrastructure.${appName};

  dataDir = "/var/lib/mongodb-4";
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -p ${dataDir}
  '';
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.mongodb oci";

    # # If you want to recreate the replicaset you may need to either:
    # # - change name
    # # - delete the data volume/path
    # replicaSetName = lib.mkOption {
    #   type = lib.types.str;
    #   description = "Initial replica set name.";
    #   default = "rs0";
    # };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address bind.";
      default = "127.0.0.1";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port to bind.";
      default = appPort;
    };
  };

  config = lib.mkIf cfg.enable {
    # https://stackoverflow.com/questions/42912755/how-to-create-a-db-for-mongodb-container-on-start-up
    infrastructure.oci-containers.backend = "podman";
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
        serviceGroup = "services";
        protocol = "mongodb";
        port = cfg.bindToPort;
        path = "";
        envPrefix = "MONGODB";
      };
      image = "mongo:4.4.29-focal";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:27017"
      ];
      bindToIp = cfg.bindToIp;
      volumes = [
        "${dataDir}:/data/db"
      ];
      # cmd = [
      #   "--replSet" "${cfg.replicaSetName}"
      # ];

      execHooks = {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      };
    };
  };
}