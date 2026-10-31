# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, pkgs, ... }:
let
  myKeys = [
    ../../keys/id_rsa_oursbook.pub
    ../../keys/id_rsa_vps_passless.pub
    ../../keys/id_sam.pub
    ../../keys/id_oursbook4.pub
    ];
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../../modules/common.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Enable networking
  networking.networkmanager.enable = true;
  # A server needs one stable IPv6 address for its AAAA record: no rotating
  # privacy addresses. What stays is the stable-privacy SLAAC address, fixed
  # for a given prefix, NetworkManager connection and
  # /var/lib/NetworkManager/secret_key.
  networking.tempAddresses = "disabled";

  # Set your time zone.
  time.timeZone = "Europe/Paris";

  # Select internationalisation properties.
  i18n.defaultLocale = "fr_FR.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "fr_FR.UTF-8";
  };

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # RDP remote login (GNOME Remote Desktop in system mode): each connection
  # gets the GDM login screen in a new headless session, so nobody has to be
  # logged in locally. The module ships the unit but, as with any
  # systemd.packages unit, its [Install] WantedBy is ignored. TLS key and
  # credentials are secrets set once with grdctl: see the README.
  services.gnome.gnome-remote-desktop.enable = true;
  systemd.services.gnome-remote-desktop.wantedBy = [ "graphical.target" ];
  # RDP from the local network only: private IPv4 ranges, IPv6 link-local and
  # ULA. The nixos-fw chain is flushed on every (re)start, so no stop command.
  networking.firewall.extraCommands = ''
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
      iptables -A nixos-fw -p tcp --dport 3389 -s "$net" -j nixos-fw-accept
    done
    for net in fe80::/10 fc00::/7; do
      ip6tables -A nixos-fw -p tcp --dport 3389 -s "$net" -j nixos-fw-accept
    done
  '';

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "fr";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "fr";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    # jack.enable = true;
  };

  # Disable auto sleep
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  #************************#
  # Garage S3 for Libr.fr  #
  #************************#

  # services.garage.enable = true;
  # services.garage.package = pkgs.garage_2;

  # Inject common config
  environments.mickours.common = {
    enable = true;
    keyFiles = myKeys;
  };
  # Add root access to mmercier
  users.users.root.openssh.authorizedKeys.keyFiles = myKeys;
  users.users.root.shell = pkgs.zsh;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # No `description`: it is the GECOS field, so it would put a full name in
  # /etc/passwd and in this repo. Same reasoning as in modules/common.nix.
  users.users."mickours" = {
    isNormalUser = true;
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
  };
  users.users."sam" = {
    isNormalUser = true;
    description = "Sam";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    openssl # to generate the RDP TLS certificate, see the README
  ];

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";

  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}
