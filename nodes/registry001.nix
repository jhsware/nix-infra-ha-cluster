{ config, pkgs, lib, ... }: {
  # config.services.harmonia = {
  #   # On first install you need generate a key pair
  #   # 
  #   #   $ nix-store --generate-binary-cache-key cache.flstr.cloud certs/cache.secret.pem certs/cache.pub.pem
  #   # 
  #   # Then copy the public key to the client node configuration
  #   #
  #   #   config.nix = {
  #   #     settings = {
  #   #       substituters = [
  #   #         "http://[%%registry001.overlayIp%%]:1099"
  #   #         "https://cache.nixos.org/"
  #   #       ];
  #   #       trusted-public-keys = [%%nix-store.trusted-public-keys%%];
  #   #     };
  #   #   };
  #   #
  #   enable = true;
  #   signKeyPaths = [
  #     "/root/certs/cache.secret.pem"
  #   ];
  #   settings = {
  #     # default ip:hostname to bind to
  #     bind = "[%%localhost.overlayIp%%]:1099";
  #     # Sets number of workers to start in the webserver
  #     workers = 4;
  #     # Sets the per-worker maximum number of concurrent connections.
  #     max_connection_rate = 256;
  #     # binary cache priority that is advertised in /nix-cache-info
  #     priority = 30;
  #   };
  # };
  config.services.dockerRegistry = {
    # https://distribution.github.io/distribution/
    # curl -I -k -s http://10.10.93.0:5000/ | head -n 1 | cut -d ' ' -f 2
    enable = true;
    enableDelete = true;
    enableGarbageCollect = true;
    listenAddress = "[%%localhost.overlayIp%%]";
    port = 5000;
    # Consider adding Haproxy TLS https://www.haproxy.com/blog/haproxy-ssl-termination
    # Consider adding insecure-registry to podman
  };

  
  config.infrastructure.podman.dockerRegistryHostPort = "[%%localhost.overlayIp%%]:5000";
  config.networking.firewall.interfaces."flannel-wg".allowedTCPPorts = [ 1099 5000 ];
}