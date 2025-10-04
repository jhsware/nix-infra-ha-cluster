{ config, pkgs, lib, ... }: {
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

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 9200 9300 9443 ];
}