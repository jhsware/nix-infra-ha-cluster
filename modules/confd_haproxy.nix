{ config, pkgs, lib, ... }: 
let
  cfg = config.infrastructure.confd_haproxy;
  cfgHaproxy = config.infrastructure.haproxy;
  hostname = config.networking.hostName;
  fileName = "haproxy.cfg";
  conf = ''
    [template]
    keys = [
      "/cluster/nodes",
      "/cluster/frontends",
      "/cluster/backends",
      "/cluster/services",
    ]

    mode = "0644"
    src = "${fileName}.tmpl"
    dest = "/etc/${fileName}"

    reload_cmd = "systemctl reload haproxy"
  '';
  template = ''
    # For inspo, check https://github.com/jhsware/infrastructure/blob/master/cli/modules/node-service-router/2_configure/templates/haproxy.cfg.tmpl
    global
      # needed for hot-reload to work without dropping packets in multi-worker mode
      stats socket /run/haproxy/haproxy.sock mode 600 expose-fd listeners level user
      log /dev/log  local0
      log /dev/log  local1 notice
      # chroot /var/lib/haproxy
      stats timeout 30s
      user ${cfgHaproxy.user}
      group ${cfgHaproxy.group}
      daemon

    defaults
      log  global
      mode  tcp
      option  dontlognull
      timeout connect 5000
      timeout client  50000
      timeout server  50000
    
    # This part is generated from cluster data found in etcd
    {{$node := json (getv "/cluster/nodes/${hostname}") -}}
    {{range $type := $node.services -}}

    ## All apps of type: {{ $type }}
    {{range $service := ls (printf "/cluster/%s" $type) -}}
    {{if (printf "/cluster/%s/%s/meta_data" $type $service) | exists}}
      {{- $meta_data := json (getv (printf "/cluster/%s/%s/meta_data" $type $service))}}
    # {{$type}}: {{$service}}
    listen tcp-in-{{$type}}-{{$service}}
      bind 127.0.0.1:{{$meta_data.publish.port}}
      use_backend {{$service}}

      backend {{$service}}
        balance roundrobin
        {{range $instance_str := getvs (printf "/cluster/%s/%s/instances/*" $type $service) -}}
          {{- $instance := json .}}
        server {{$instance.node}} {{$instance.ipv4}}:{{$instance.port}} check
        {{- end}}
    {{end -}}
    {{end -}}
    {{end -}}
    
  '';
in
{
  options.infrastructure.confd_haproxy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable confd haproxy template.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."confd/conf.d/${fileName}.toml".text = conf;
    environment.etc."confd/templates/${fileName}.tmpl".text = template;

    # environment.etc."haproxy.cfg".source = lib.readFile /etc/haproxy.cfg;
    # lib.mkIf (lib.pathExists "/etc/haproxy.cfg") {
    #   environment.etc."haproxy.cfg".source = lib.readFile /etc/haproxy.cfg;
    # }
  };
}
