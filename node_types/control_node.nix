{ pkgs, ... }:
let
  # remco = pkgs.callPackage (import ./remco-pkg.nix) { };
  etcdCluster = [ [%%etcdCluster%%] ];
  etcdClusterToken = "[%%etcdClusterToken%%]";
in
{
  config.infrastructure.etcd = {
    enable = true;
    initialClusterToken = "${etcdClusterToken}";
    initialCluster = etcdCluster;
  };
}