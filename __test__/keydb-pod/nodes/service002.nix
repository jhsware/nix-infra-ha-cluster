{ config, pkgs, lib, ... }: {
  config.infrastructure.keydb-ha = {
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    replicaOf = [
      { host = "[%%service001.overlayIp%%]"; port = 6380; }
      { host = "[%%service003.overlayIp%%]"; port = 6380; }
    ];
  };

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 6380 ];
}