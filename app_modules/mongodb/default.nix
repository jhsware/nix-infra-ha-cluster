{ config, pkgs, lib, ... }:
let
  appName = "mongodb";
  appPort = 27017;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.mongodb native";

    # If you want to recreate the replicaset you may need to either:
    # - change name
    # - delete the data volume/path
    replicaSetName = lib.mkOption {
      type = lib.types.str;
      description = "Replica set name for clustering.";
      default = "rs0";
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

    dbPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to store MongoDB data.";
      default = "/var/lib/mongodb";
    };
  };

  config = lib.mkIf cfg.enable {
    # Use the native NixOS MongoDB service
    services.mongodb = {
      enable = true;
      package = pkgs.mongodb-ce;
      bind_ip = "127.0.0.1,${cfg.bindToIp}";
      dbpath = cfg.dbPath;
      extraConfig = ''
        replication:
          replSetName: ${cfg.replicaSetName}
      '';
    };

    # Install mongosh for administration
    environment.systemPackages = with pkgs; [
      mongosh
    ];

    # Open firewall for MongoDB on the overlay network interface
    # This is typically configured per-node, but we provide the option here
  };
}
