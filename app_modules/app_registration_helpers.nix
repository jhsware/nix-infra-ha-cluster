pkgs: lib: config: cfg: service:
let
  hostName = config.networking.hostName;
  etcdClusterNodes = lib.concatMapStringsSep "," (n: "https://${n.ip}:2379") config.infrastructure.confd.etcdCluster;
  etcdctlEnvVars = config.infrastructure.confd.etcdctlEnvVars;
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${etcdctlEnvVars}
    # Register service before systemctl started
    ${pkgs.etcd}/bin/etcdctl --endpoints=${etcdClusterNodes} put /cluster/${service.group}/${service.name}/meta_data '${builtins.toJSON service.serviceMetaData}'
  '';
  execStartPostScript = pkgs.writeShellScript "postStart" ''
    ${etcdctlEnvVars}
    # Register instance on systemctl started
    ${pkgs.etcd}/bin/etcdctl --endpoints=${etcdClusterNodes} put /cluster/${service.group}/${service.name}/instances/${hostName} '${builtins.toJSON service.instanceEntry}'
  '';
  execStopPreScript = pkgs.writeShellScript "preStop" ''
    ${etcdctlEnvVars}
    # Remove instance on systemctl stopped
    ${pkgs.etcd}/bin/etcdctl --endpoints=${etcdClusterNodes} del /cluster/${service.group}/${service.name}/instances/${hostName}
  '';
  mkServiceConfig = { ExecStartPre ? [], ExecStartPost ? [], ExecStopPre ? [] }: {
    ExecStartPre = ExecStartPre ++ [
      execStartPreScript
    ];
    ExecStartPost = ExecStartPost ++ [
      execStartPostScript
    ];
  
    ExecStopPre = ExecStopPre ++ [
      execStopPreScript
    ];
  };
in
{
  inherit mkServiceConfig;
}