{ config, lib, pkgs, ... }:
let
  cfg = config.infrastructure.flannel;
  hostname = config.networking.hostName;
  flannelWatchdogScript = ''
    #!/usr/bin/env bash
    # Threshold for CPU usage (in percentage)
    CPU_THRESHOLD=80.0
    LOW_CPU_THRESHOLD=10.0
    
    # Get the CPU usage of the flannel process
    CPU_USAGE=$(ps -C flannel -o %cpu= | awk '{sum+=$1} END {print sum}')

    # Check if CPU usage exceeds the threshold
    # NOTE: The ! is used to match awk comparison output with how if statements work
    if awk "BEGIN {exit !($CPU_USAGE > $CPU_THRESHOLD)}"; then
      echo "CPU usage of flannel is too high: $CPU_USAGE%. Restarting flannel..."
      systemctl restart flannel
    elif awk "BEGIN {exit !($CPU_USAGE > $LOW_CPU_THRESHOLD)}"; then
      echo "CPU usage of flannel is within limits: $CPU_USAGE%"
    fi
  '';
in
{
  options.infrastructure.flannel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable flannel for networking";
    };

    etcdCluster = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "Initial etcd cluster IPs.";
      example = "[ { name = \"etcd001\"; ip = \"168.0.0.0\" { name = \"etcd002\"; ip = \"168.0.0.1\" } ]";
    };
  };

  config = lib.mkIf cfg.enable {
    services.flannel = {
      enable = true;

      storageBackend = "etcd";
      etcd = {
        endpoints = map (node: "https://${node.ip}:2379") cfg.etcdCluster;
        caFile = "/root/certs/ca-chain.cert.pem";
        certFile = "/root/certs/${hostname}-client-tls.cert.pem";
        keyFile = "/root/certs/${hostname}-client-tls.key.pem";
      };
      backend = {
        Type = "wireguard";
        PersistentKeepaliveInterval = 60;
      };
      network = "10.0.0.0/8";
      subnetMin = "10.10.0.0";
      subnetMax = "10.99.0.0";
    };

    systemd.services."flannel-watchdog" = {
      script = flannelWatchdogScript;
      path = [ pkgs.procps pkgs.gawk ];
      serviceConfig = {
        Type = "simple";
        User = "root";
      };
    };

    systemd.timers."flannel-watchdog" = {
      wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "5m";
          Unit = "flannel-watchdog.service";
        };
    };
  };
}