{ config, pkgs, lib, ... }: {
  config.infrastructure.mongodb = {
    enable = true;
    replicaSetName = "rs0";
    bindToIp = "[%%localhost.overlayIp%%]";
  };

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 27017 ];
}
