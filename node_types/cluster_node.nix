{ config, pkgs, ... }:
let
  # remco = pkgs.callPackage (import ./remco-pkg.nix) { };
  etcdCluster = [ [%%etcdCluster%%] ];
in
{
  config.infrastructure.flannel = {
    enable = true;
    etcdCluster = etcdCluster;
  };

  config.infrastructure.confd = {
    enable = true;
    etcdCluster = etcdCluster;
  };

  config.environment.systemPackages = with pkgs; [
    # We want these so we can run the etcdctl command
    etcd
    wireguard-tools
  ];

  # This is used to test that confd is working and can talk to etcd
  config.infrastructure.confd_test.enable = true;
  
  # This is the haproxy service router
  config.infrastructure.haproxy.enable = true;
  config.infrastructure.confd_haproxy.enable = true;

  # Enable podman to run containers
  config.infrastructure.podman.enable = true;
}