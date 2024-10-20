{ config, pkgs, lib, ... }:
let
  SSL = {
    # addSSL = true;
    enableACME = true;
    forceSSL = true;
  };
in {
  config = {
    infrastructure.podman.dockerRegistryHostPort = "[%%registry001.overlayIp%%]:5000";

    # https://nixos.wiki/wiki/Nginx
    # https://search.nixos.org/options?channel=24.05&from=0&size=30&sort=relevance&type=packages&query=services.nginx
    services.nginx.enable = true;

    # services.nginx.virtualHosts."your.domain.org" = SSL // {
    #     locations."/".proxyPass = "http://127.0.0.1:11211/";
    #     # serverAliases = [ "www.myhost.org" ];
    # };

    # services.nginx.virtualHosts."another.domain.org" = SSL // {
    #     locations."/".proxyPass = "http://127.0.0.1:11311/";
    #     # serverAliases = [ "www.myhost.org" ];
    # };

    security.acme = {
      acceptTerms = true;
      defaults.email = "your-email@example.org";
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}