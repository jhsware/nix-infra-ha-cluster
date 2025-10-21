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

  config.infrastructure.mongodb-4 = {
    enable = true;
    replicaSetName = "rs0";
    bindToIp = "[%%localhost.overlayIp%%]";
  };

  config.infrastructure.mariadb-cluster = {
    enable = true;
    clusterName = "my_galera_cluster";
    nodeName = "[%%localhost.hostname%%]";
    bindToIp = "[%%localhost.overlayIp%%]";
    nodeAddresses = [
      "[%%service001.overlayIp%%]"
      "[%%service002.overlayIp%%]"
      "[%%service003.overlayIp%%]"
    ];
    rootPassword = "your-secure-password";
  };


  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [
    27017 # Mongodb
    3306 4567 4568 4444 # Mariadb
  ];
  config.networking.firewall.interfaces."flannel-wg".allowedUDPPorts = [
    4567 # Mariadb
  ];
}