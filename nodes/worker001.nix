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

  config.infrastructure.app-mongodb-pod = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    mongodbConnectionString = "mongodb://[%%service001.overlayIp%%]:27017,[%%service002.overlayIp%%]:27017,[%%service003.overlayIp%%]:27017/test?replicaSet=rs0&connectTimeoutMS=1000";
    # mongodbConnectionString = "mongodb://[%%service001.overlayIp%%]:27017/test?connectTimeoutMS=1000";
  };

  config.infrastructure.app-mariadb-pod = {
    # TODO: Update test script and create a docker image
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    mariadbConnectionStringSecretName = "[%%secrets/mariadb.test-admin.connectionString%%]";
  };

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 11211 11311 11411 11511 11611 ];
}