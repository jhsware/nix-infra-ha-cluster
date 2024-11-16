{ config, pkgs, lib, ... }:
let
  appName = "app-elasticsearch-pod";
  # appUser = "app-mongodb-pod";
  appPort = 11511;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.${appName} oci";

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

    elasticsearchConnectionString = lib.mkOption {
      type = lib.types.str;
      description = "Elasticsearch connection string.";
      default = "127.0.0.1";
    };

    # secretName = lib.mkOption {
    #   type = lib.types.str;
    #   description = "Name of the installed systemd credential.";
    # };
  };

  config = lib.mkIf cfg.enable {
    # users.users."${appUser}" = {
    #   isSystemUser = true;
    #   createHome = false;
    # };

    # https://docs.keydb.dev/docs/docker-active-rep/
    infrastructure.oci-containers.backend = "podman";
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
        serviceGroup = "frontends";
        port = cfg.bindToPort;
        path = "";
        envPrefix = "APP_MONGODB_POD";
      };
      image = "${config.infrastructure.podman.dockerRegistryHostPort}/apps/ceb360d346bd";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:3010"
      ];
      bindToIp = cfg.bindToIp;
      # environmentSecrets = [
      #   { name = cfg.secretName; envVar="MY_TEST"; }
      # ];
      environment = {
        # CONNECTION_STRING =  "mongodb://10.10.66.0:27017,10.10.49.0:27017,10.10.90.0,27017/test?replicaSet=rs0&connectTimeoutMS=1000";
        CONNECTION_STRING = cfg.elasticsearchConnectionString;
        NODE_ENV = "production";
      };
    };

  };
}
