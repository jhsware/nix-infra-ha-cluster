{ config, pkgs, lib, ... }: {
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

  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 3306 4567 4568 4444 ];
  config.networking.firewall.interfaces."flannel-wg".allowedUDPPorts = [ 4567 ];
}