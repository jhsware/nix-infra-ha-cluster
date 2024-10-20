{ config, pkgs, lib, ... }: 
let
  cfg = config.infrastructure.confd_test;
  fileName = "test.txt";
  conf = ''
    [template]
    keys = [
      "/cluster/nodes",
    ]

    mode = "0644"
    src = "${fileName}.tmpl"
    dest = "/root/${fileName}"

    # reload_cmd = "systemctl reload haproxy"
  '';
  template = ''
    {{range getvs "/cluster/nodes/*" -}}
      {{$node := json . -}}
      name: {{$node.name}}
      ip: {{$node.ipv4}}
    {{end -}}
  '';
in
{
  options.infrastructure.confd_test = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable confd test template.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."confd/conf.d/${fileName}.toml".text = conf;
    environment.etc."confd/templates/${fileName}.tmpl".text = template;
  };
}
