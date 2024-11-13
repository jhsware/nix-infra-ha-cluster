{ config, pkgs, lib, ... }: {
  config.nix = {
    settings = {
      substituters = [
        "http://[%%registry001.overlayIp%%]:1099"
        "https://cache.nixos.org/"
      ];
      trusted-public-keys = [%%nix-store.trusted-public-keys%%];
    };
  };

  config.infrastructure.podman.dockerRegistryHostPort = "[%%registry001.overlayIp%%]:5000";

  config.infrastructure.app-pod = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    secretName = "[%%secrets/my.test%%]";
  };

  config.infrastructure.app-mongodb-pod = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    mongodbConnectionString = "mongodb://[%%service001.overlayIp%%]:27017,[%%service002.overlayIp%%]:27017,[%%service003.overlayIp%%]:27017/test?replicaSet=rs0&connectTimeoutMS=1000";
    # mongodbConnectionString = "mongodb://[%%service001.overlayIp%%]:27017/test?connectTimeoutMS=1000";
  };

  config.infrastructure.app-redis-pod = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    # redisConnectionString = "redis://[%%service001.overlayIp%%]:27017,[%%service002.overlayIp%%]:27017,[%%service003.overlayIp%%]:27017/";
    # redisConnectionString = "redis://127.0.0.1:6380/";
    redisConnectionStringSecretName = "[%%secrets/keydb.connectionString%%]";
  };

  config.infrastructure.app-elasticsearch-pod = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    # elasticsearchConnectionString = "http://[%%service001.overlayIp%%]:9200,[%%service002.overlayIp%%]:9200,[%%service003.overlayIp%%]:9200/";
    elasticsearchConnectionString = "http://127.0.0.1:9200/";
  };

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 11211 11311 11411 11511 ];
}