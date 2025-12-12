{ config, pkgs, lib, ... }: {
  config.services.dockerRegistry = {
    # https://distribution.github.io/distribution/
    # curl -I -k -s http://10.10.93.0:5000/ | head -n 1 | cut -d ' ' -f 2
    enable = true;
    enableDelete = true;
    enableGarbageCollect = true;
    listenAddress = "127.0.0.1";
    port = 5000;
    # Consider adding Haproxy TLS https://www.haproxy.com/blog/haproxy-ssl-termination
    # Consider adding insecure-registry to podman
  };

  config.infrastructure.podman.dockerRegistryHostPort = "127.0.0.1:5000";

  config.infrastructure.app-mariadb-pod = {
    # TODO: Update test script and create a docker image
    enable = true;
    bindToIp = "[%%localhost.overlayIp%%]";
    mariadbConnectionStringSecretName = "[%%secrets/mariadb.test-admin.connectionString%%]";
  };
}