{
  imports = [
    ./etcd.nix
    ./flannel.nix
    ./confd.nix
    ./confd_test.nix
    ./haproxy.nix
    ./confd_haproxy.nix
    ./oci-containers.nix
    ./podman.nix
  ];
}