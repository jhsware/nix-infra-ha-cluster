{ config, pkgs, lib, ... }: 
let
  cfg = config.infrastructure.confd;
  hostname = config.networking.hostName;
  # https://github.com/kelseyhightower/confd/blob/master/docs/configuration-guide.md
  nodes = map (node: "https://${node.ip}:2379") cfg.etcdCluster;
  confdCfg = ''
    backend = "etcdv3"
    confdir = "/etc/confd"
    interval = 10
    nodes = [ ${lib.concatMapStringsSep "," (s: ''"${s}"'') nodes}, ]
    log-level = "debug"
    scheme = "https"
    watch = true

    client_cakeys = "/root/certs/ca-chain.cert.pem"
    client_cert = "/root/certs/${hostname}-client-tls.cert.pem"
    client_key = "/root/certs/${hostname}-client-tls.key.pem"
    noop = false
  '';
  package = pkgs.confd;
in
{
  options.infrastructure.confd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable confd for orchestration of service mesh etc.";
    };

    etcdCluster = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "Initial etcd cluster IPs.";
      example = "[ { name = \"etcd001\"; ip = \"168.0.0.0\" { name = \"etcd002\"; ip = \"168.0.0.1\" } ]";
    };

    etcdctlEnvVars = lib.mkOption {
      type = lib.types.str;
      description = "The etcdctl env vars configuration access to certs etc.";
      default = ''
        export ETCDCTL_DIAL_TIMEOUT=3s
        export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
        export ETCDCTL_CERT=/root/certs/${hostname}-client-tls.cert.pem
        export ETCDCTL_KEY=/root/certs/${hostname}-client-tls.key.pem
        export ETCDCTL_API=3
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.confd = {
      description = "Confd Service.";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p /etc/confd/conf.d"
          "${pkgs.coreutils}/bin/mkdir -p /etc/confd/templates"
        ];
        # StateDirectory = "/etc/confd/conf.d:/etc/confd/templates";
        ExecStart = "${package}/bin/confd";
      };
    };

    environment.etc."confd/confd.toml".text = confdCfg;

    environment.systemPackages = [ package ];
  };
}
