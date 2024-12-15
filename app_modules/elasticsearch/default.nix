{ config, pkgs, lib, ... }:
let
  appName = "elasticsearch";
  # appUser = "elasticsearch";
  appPort = 9200;

  cfg = config.infrastructure.${appName};

  clusterMembers = "[ ${builtins.concatStringsSep ", " (map (attr: "\"${attr.host}\"") cfg.clusterMembers)} ]";
  clusterMasterNodes = "[ ${builtins.concatStringsSep ", " (map (attr: "\"${attr.name}\"") cfg.clusterMembers)} ]";
  elasticYML = pkgs.writeText "elasticsearch.yml" ''
    cluster.name: ${cfg.clusterName}
    node.name: ${config.networking.hostName}
    path.data: /usr/share/elasticsearch/data
    path.logs: /usr/share/elasticsearch/logs
    logger.org.elasticsearch.discovery: WARN
    
    # https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-network.html
    network.bind_host: 0.0.0.0 # Listen to all incoming traffic in container
    network.publish_host: ${cfg.bindToIp} # Advertise the actual ip of the node
    http.port: 9200
    transport.port: 9300
    remote_cluster.port: 9443

    # https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-discovery-settings.html
    # https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-discovery-bootstrap-cluster.html
    node.roles: [ data, master ]
    discovery.seed_hosts: ${clusterMembers}
    cluster.initial_master_nodes: ${clusterMasterNodes}

    # https://www.elastic.co/guide/en/elasticsearch/reference/8.13/bootstrap-checks-xpack.html#bootstrap-checks-tls
    # https://www.elastic.co/guide/en/elasticsearch/reference/current/security-settings.html
    xpack.security.enabled: true
    xpack.security.autoconfiguration.enabled: true
    xpack.security.http.ssl.enabled: false
    xpack.security.transport.ssl.enabled: false
    xpack.security.remote_cluster_server.ssl.enabled: false
    xpack.security.remote_cluster_client.ssl.enabled: false

  '';

  dataDir = "/var/lib/elasticsearch-cluster";

  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -m 750 -p ${dataDir}
    ${pkgs.coreutils}/bin/chown 1000:1000 ${dataDir}
  '';
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.elasticsearch cluster oci";

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Name of cluster.";
      default = "elastic-cluster";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address bind.";
      default = "127.0.0.1";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port to bind.";
      default = appPort;
    };

    clusterMembers = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "Replica of.";
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    # started with infrastructure recipe
    infrastructure.oci-containers.backend = "podman";
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
        serviceGroup = "services";
        protocol = "http";
        port = cfg.bindToPort;
        path = "";
        envPrefix = "ELASTICSEARCH";
      };
      image = "elasticsearch:8.13.4";
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:9200"
        "${cfg.bindToIp}:9300:9300"
        "${cfg.bindToIp}:9443:9443"
      ];
      bindToIp = cfg.bindToIp;
      volumes = [
        "${dataDir}:/usr/share/elasticsearch/data"
        "${elasticYML}:/usr/share/elasticsearch/config/elasticsearch.yml"
      ];

      execHooks = {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      };
    };
  };
}