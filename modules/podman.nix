{ config, pkgs, lib, ... }:
let
  cfg = config.infrastructure.podman;
in
{
  options.infrastructure.podman = {
    enable = lib.mkEnableOption "infrastructure.podman";

    dockerRegistryHostPort = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Docker Registry IP address";
      default = null;
    };
  };

  config = lib.mkIf cfg.enable {

    # Enable common container config files in /etc/containers
    virtualisation.containers.enable = true;
    virtualisation = {
      podman = {
        enable = true;

        # Create a `docker` alias for podman, to use it as a drop-in replacement
        dockerCompat = true;

        # Required for containers under podman-compose to be able to talk to each other.
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    # Add insecure registry
    virtualisation.containers.registries = lib.mkIf (cfg.dockerRegistryHostPort != null) {
      insecure = [ "${cfg.dockerRegistryHostPort}" ];
    };

    # Useful development tools
    environment.systemPackages = with pkgs; [
      # dive # look into docker image layers
      podman-tui # status of containers in the terminal
      # docker-compose # start group of containers for dev
      podman-compose # start group of containers for dev
    ];
  };
}