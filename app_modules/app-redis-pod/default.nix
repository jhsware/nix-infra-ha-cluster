{ config, pkgs, lib, ... }:
let
  appName = "app-redis-pod";
  # appUser = "app-mongodb-pod";
  appPort = 11411;

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

    redisConnectionStringSecretName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the installed systemd credential.";
    };
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
      image = "${config.infrastructure.podman.dockerRegistryHostPort}/apps/dfec6beb8daa";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:3010"
      ];
      bindToIp = cfg.bindToIp;
      environment = {
        # CONNECTION_STRING = cfg.redisConnectionString;
        # CONNECTION_STRING = "redis://${cfg.redisPassword}@127.0.0.1:6380";
        NODE_ENV = "production";
      };
      environmentSecrets = [
        { name = cfg.redisConnectionStringSecretName; envVar="CONNECTION_STRING"; }
      ];
    };

  };
}
