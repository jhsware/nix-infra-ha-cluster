{ config, pkgs, lib, ... }:
let
  appName = "app-mariadb-pod";
  # appUser = "app-mariadb-pod";
  appPort = 11611;
  expose = 3014;

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

    mariadbConnectionStringSecretName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the installed systemd credential.";
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
        envPrefix = "APP_MARIADB_POD";
      };
      image = "${config.infrastructure.podman.dockerRegistryHostPort}/apps/app-mariadb-pod:latest";
      autoStart = true;
      networkType = "host";
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:${toString cfg.bindToPort}"
      ];
      bindToIp = cfg.bindToIp;
      # environmentSecrets = [
      #   { name = cfg.secretName; envVar="MY_TEST"; }
      # ];
      environment = {
        NODE_ENV = "production";
        EXPOSE = "${toString cfg.bindToPort}";
      };
      environmentSecrets = [
        # mariadbConnectionString = "mysql://username:password@[%%service001.overlayIp%%]:3306,[%%service002.overlayIp%%]:3306,[%%service003.overlayIp%%]:3306/db?connectionLimit=10&failoverServer=true&multipleStatements=true";
        { name = cfg.mariadbConnectionStringSecretName; envVar="CONNECTION_STRING"; }
      ];
    };

  };
}
