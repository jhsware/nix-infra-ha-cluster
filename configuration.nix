{ lib, pkgs, ... }:
let
  sshPort = 22;
  sshKey = "[%%sshKey%%]";
  nixVersion = "[%%nixVersion%%]"; # 24.05
  nodeName = "[%%nodeName%%]"; # node001

  clusterNode = lib.fileset.toList (lib.fileset.maybeMissing ./cluster_node.nix);
  controlNode = lib.fileset.toList (lib.fileset.maybeMissing ./control_node.nix);
  nodeConfig = lib.fileset.toList (lib.fileset.maybeMissing ./[%%nodeName%%].nix);
  modules = lib.fileset.toList (lib.fileset.maybeMissing ./modules/default.nix);
  appModules = lib.fileset.toList (lib.fileset.maybeMissing ./app_modules/default.nix);
in
{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix # generated at runtime by nixos-infect 
  ] ++ clusterNode ++ controlNode ++ nodeConfig ++ modules ++ appModules;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  system.stateVersion = nixVersion;

  networking.hostName = nodeName;
  networking.domain = "";
  users.users.root.openssh.authorizedKeys.keys = [ sshKey ];
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ sshPort ];
  networking.firewall.allowedUDPPorts = [ ];

  networking = {
    vlans = {
      vlan100 = { id=100; interface="eth0"; };
    };
    interfaces.vlan100.ipv4.addresses = [{
      address = "192.168.1.1";
      prefixLength = 28;
    }];
  };

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;
  services.openssh.settings.LogLevel = "ERROR";
  services.openssh.settings.Macs = [
    "hmac-sha2-512-etm@openssh.com"
    "hmac-sha2-512" # Required for dartssh
    "hmac-sha2-256-etm@openssh.com"
    "hmac-sha2-256" # Required for dartssh
    "umac-128-etm@openssh.com"
  ];

  services.rsyncd.enable = true;

  # Enable Flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [
    # Flakes clones its dependencies through the git command
    git
  ];
}