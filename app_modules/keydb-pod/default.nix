{ config, pkgs, lib, ... }:
let
  appName = "keydb-ha-pod";
  # appUser = "keydb";
  appPort = 6380;

  cfg = config.infrastructure.${appName};

  # https://docs.keydb.dev/docs/config-file/
  redisConf = pkgs.writeText "redis.conf" ''
    port 6380
    bind 0.0.0.0
    appendonly yes
    loglevel debug
    protected-mode no
    dir /data/db

    # https://docs.keydb.dev/docs/acl
    requirepass SUPER_SECRET_PASSWORD
    masterauth  SUPER_SECRET_PASSWORD

    # https://docs.keydb.dev/docs/multi-master
    multi-master yes
    active-replica yes
    ${builtins.concatStringsSep "\n" (map (attr: "replicaof ${attr.host} ${builtins.toString attr.port}") cfg.replicaOf)}
  '';

  dataDir = "/var/lib/keydb-ha";
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -m 750 -p ${dataDir}
  '';
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.keydb ha oci";

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

    replicaOf = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "Replica of.";
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    # https://docs.keydb.dev/docs/docker-active-rep/
    infrastructure.oci-containers.backend = "podman";
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
        serviceGroup = "services";
        protocol = "redis";
        port = cfg.bindToPort;
        path = "";
        envPrefix = "REDIS";
      };
      image = "eqalpha/keydb:alpine_x86_64_v6.3.4";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:6380"
      ];
      bindToIp = cfg.bindToIp;
      volumes = [
        "${dataDir}:/data/db"
        "${redisConf}:/etc/keydb/redis.conf"
      ];

      execHooks = {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      };
    };
  };
}

# FROM redis
# COPY redis.conf /usr/local/etc/redis/redis.conf
# CMD [ "redis-server", "/usr/local/etc/redis/redis.conf" ]