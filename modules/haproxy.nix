# SOURCE: https://github.com/NixOS/nixpkgs/blob/94cf7253bdf8b4b4d20fd2bba93047f8d3a1bb83/pkgs/tools/networking/haproxy/default.nix#L25
{ config, lib, pkgs, ... }:

let
  cfg = config.infrastructure.haproxy;

  # The following file should be generated from cluster data in etcd
  # dynamicHaproxyConfig = if builtins.pathExists ./dynamic-haproxy-config.cfg then builtins.readFile ./dynamic-haproxy-config.cfg else "";

  haproxyCfg = ''
      log /dev/log  local0
      log /dev/log  local1 notice
      # chroot /var/lib/haproxy
      stats timeout 30s
      user ${cfg.user}
      group ${cfg.group}
      daemon

    defaults
      log  global
      mode  tcp
      option  dontlognull
      timeout connect 5000
      timeout client  50000
      timeout server  50000
    
    # This part is generated from cluster data found in etcd
  '';

in
{
  options.infrastructure.haproxy = {
    enable = lib.mkEnableOption (lib.mdDoc "HAProxy, the reliable, high performance TCP/HTTP load balancer.");

    package = lib.mkPackageOptionMD pkgs "haproxy" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "haproxy";
      description = lib.mdDoc "User account under which haproxy runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "haproxy";
      description = lib.mdDoc "Group account under which haproxy runs.";
    };

    # config = mkOption {
    #   type = types.nullOr types.lines;
    #   default = null;
    #   description = lib.mdDoc ''
    #     Contents of the HAProxy configuration file,
    #     {file}`haproxy.conf`.
    #   '';
    # };
  };

  config = lib.mkIf cfg.enable {
    # mkdir /run/haproxy
    # mkdir /var/lib/haproxy

    # systemd.tmpfiles.rules = [
    #   "d /var/lib/haproxy 0755 ${cfg.user} ${cfg.group} -"
    #   "d /run/haproxy 0755 ${cfg.user} ${cfg.group} -"
    # ];


    services.haproxy = {
      enable = true;
      user = cfg.user;
      group = cfg.group;
      package = cfg.package;
      config = haproxyCfg;
    };

    # Permission denied
    # # We want to trigger a re-render based on etcd-data because this recipe overwrites haproxy.cfg
    # systemd.services.haproxy.serviceConfig.ExecStartPost = [
    #   "${pkgs.systemd}/bin/systemctl restart confd"
    # ];
  };
}