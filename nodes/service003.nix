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

  # config.infrastructure.redis-cluster-pod = {
  #   enable = true;
  #   bindToIp = "10.10.43.0";
  # };

  config.infrastructure.keydb-ha = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    replicaOf = [
      { host = "[%%service001.overlayIp%%]"; port = 6380; }
      { host = "[%%service002.overlayIp%%]"; port = 6380; }
    ];
  };
  
  config.infrastructure.elasticsearch = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    clusterName = "elasticsearch";
    clusterMembers = [
      { host = "[%%service001.overlayIp%%]"; name = "service001"; }
      { host = "[%%service002.overlayIp%%]"; name = "service002"; }
      { host = "[%%service003.overlayIp%%]"; name = "service003"; }
    ];
  };

  config.infrastructure.mariadb-cluster = {
    enable = true;
    clusterName = "my_galera_cluster";
    bindToIp = "[%%localhost.overlayIp%%]";
    nodeAddresses = [
      "[%%service001.overlayIp%%]"
      "[%%service002.overlayIp%%]"
      "[%%service003.overlayIp%%]"
    ];
    rootPassword = "your-secure-password";
  };

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 27017 6380 9200 9300 9443 3306 4567 4568 4444 ];
  # config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 27017 6380 9200 9300 9443 ];
  config.networking.firewall.interfaces."flannel-wg".allowedUDPPorts = [ 4567 ];
}
