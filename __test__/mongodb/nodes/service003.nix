{ config, pkgs, lib, ... }: {
  config.infrastructure.mongodb-4 = {
    enable = true;
    replicaSetName = "rs0";
    bindToIp = "[%%localhost.overlayIp%%]";
  };

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 27017 ];
  config.networking.firewall.interfaces."flannel-wg".allowedUDPPorts = [];
}