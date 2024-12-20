{ config, pkgs, lib, ... }:
let
  appName = "app-pod";
  # appUser = "app-pod";
  appPort = 11211;
  expose = 3010;

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

    secretName = lib.mkOption {
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
        envPrefix = "APP_POD";
      };
      image = "${config.infrastructure.podman.dockerRegistryHostPort}/apps/898aea81215a";
      autoStart = true;
      networkType = "host";
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:${toString cfg.bindToPort}"
      ];
      bindToIp = cfg.bindToIp;
      environment = {
        EXPOSE = "${toString cfg.bindToPort}";
      };
      environmentSecrets = [
        { name = cfg.secretName; envVar="MY_TEST"; }
      ];
    };
  };
}
