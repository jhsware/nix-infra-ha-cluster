{ config, pkgs, lib, ... }: 
let 
  cfg = config.infrastructure.etcd;
  hostname = config.networking.hostName;
  hostip = (builtins.head config.networking.interfaces.eth0.ipv4.addresses).address;
in
{
  options.infrastructure.etcd = {
    enable = lib.mkEnableOption "infrastructure.etcd";

    initialClusterToken = lib.mkOption {
      type = lib.types.str;
      description = "Initial cluster token.";
      example = "fa345316-610c-11e9-a253-93f7b84e541f";
    };

    initialCluster = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "Initial etcd cluster IPs.";
      example = "[ { name = \"etcd001\"; ip = \"168.0.0.0\" { name = \"etcd002\"; ip = \"168.0.0.1\" } ]";
    };
  };
  
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ 2379 2380 ];
    networking.firewall.allowedUDPPorts = [ ];

    # etcd security settings https://etcd.io/docs/v3.2/op-guide/security/
    # Static method for clusters: https://etcd.io/docs/v3.4/op-guide/clustering/#static
    services.etcd =
      {
        enable = true;
        name = hostname;

        # TLS settings
        trustedCaFile = /root/certs/ca-chain.cert.pem;
        
        peerClientCertAuth = true;
        peerKeyFile = /root/certs/${hostname}-peer-tls.key.pem;
        peerCertFile = /root/certs/${hostname}-peer-tls.cert.pem;

        clientCertAuth = true;
        keyFile = /root/certs/${hostname}-client-tls.key.pem;
        certFile = /root/certs/${hostname}-client-tls.cert.pem;


        advertiseClientUrls = [ "https://${hostip}:2379" ];
        listenClientUrls = [ "https://0.0.0.0:2379" "https://127.0.0.1:4001" ];

        initialAdvertisePeerUrls = [ "https://${hostip}:2380" ];
        listenPeerUrls = [ "https://0.0.0.0:2380" ];

        # Specify the cluster token so no unintended cross-cluster interaction
        initialClusterToken = cfg.initialClusterToken;
        # Tell each cluster the advertised peer url of other etcd nodes (static method)
        # initialCluster = lib.attrsets.mapAttrsToList toClusterEntry addressMap;
        initialCluster = map (node: "${node.name}=https://${node.ip}:2380") cfg.initialCluster;
        initialClusterState = "new";
      };
  };

    # To run etcd in nixos containers, look at:
    # https://discourse.nixos.org/t/issues-using-nixos-container-to-set-up-an-etcd-cluster/8438
    # https://github.com/mt-caret/nixos-jepsen.etcdemo/blob/master/etcd-cluster.nix   

}