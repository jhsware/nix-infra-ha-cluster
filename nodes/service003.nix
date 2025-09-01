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

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 27017 ];
  config.networking.firewall.interfaces."flannel-wg".allowedUDPPorts = [];
}