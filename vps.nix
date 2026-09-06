{
  config,
  pkgs,
  leProjetDeVie,
  ...
}:
let
  webPort = 80;
  webSslPort = 443;
  myKeys = [
    ./keys/id_rsa_oursbook.pub
    ./keys/id_rsa_vps_passless.pub
  ];
  exiftool_13_44 = pkgs.exiftool.overrideAttrs (oldAttrs: rec {
    src = pkgs.fetchFromGitHub {
      owner = "exiftool";
      repo = "exiftool";
      tag = version;
      hash = "sha256-o9/qg+BQSc2MiZIqvyFKPtCBHU64QLMhA2AcvDCph04=";
    };
    version = "13.44";
  });
  bitwardenFQDN = "bitwarden.libr.fr";
  facerecognition = pkgs.callPackage ./pkgs/nextcloud-app-facerecognition { };
in
{
  system.stateVersion = "26.05";
  nix.settings.trusted-users = [ "@wheel" ];

  # Needed for rsync backups
  programs.zsh.enable = true;

  imports = [
    # Include the results of the hardware scan.
    ./vps-hardware-configuration.nix
    # Common config
    ./modules/common.nix
  ];

  services.le-projet-de-vie = {
    enable = true;
    nginx = {
      enable = true;
      hostName = "le-projet-de-vie.libr.fr";
    };
    package = leProjetDeVie.default;
  };
  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/vda"; # or "nodev" for efi only

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  services.openssh.settings.PasswordAuthentication = false;
  environments.mickours.common = {
    enable = true;
    keyFiles = myKeys;
  };
  # Add root access to mmercier
  users.users.root.openssh.authorizedKeys.keyFiles = myKeys;
  users.users.root.shell = pkgs.zsh;

  # Add other users
  # users.extraUsers.beatrice = {
  #   description = "Béatrice Mayaux";
  #   isNormalUser = true;
  #   openssh.authorizedKeys.keyFiles = [ ./keys/id_rsa_beatrice.pub ];
  #   uid = 1003;
  # };

  time.timeZone = "Europe/Paris";

  # Avoid using to much space with the logs
  services.journald.extraConfig = "SystemMaxUse=100M";

  # Common config
  lib.environments.mickours.common.enable = true;

  # Let's encrypt security settings of ACME
  security.acme.defaults.email = "admin@libr.fr";
  security.acme.acceptTerms = true;
  security.acme.certs = {
    "libr.fr" = {
      webroot = "/var/lib/acme/acme-challenge/";
      email = "admin@libr.com";
      extraDomainNames = [
        "mail.libr.fr"
      ];
    };
  };

  #*************#
  #    Nginx    #
  #*************#

  services.nginx = {
    enable = true;
    appendHttpConfig = ''
      server_names_hash_bucket_size 64;
    '';
    virtualHosts = {
      "nextcloud.libr.fr".forceSSL = true;
      "nextcloud.libr.fr".enableACME = true;

      "bgremove.libr.fr".forceSSL = true;
      "bgremove.libr.fr".enableACME = true;

      "${bitwardenFQDN}".enableACME = true;

      "michaelmercier.fr" = {
        locations."/" = {
          root = "/data/public/mmercier/website";
        };
        # Static file serving
        locations."/files/" = {
          root = "/data/public/mmercier";
          extraConfig = ''
            autoindex on;
          '';
        };
      };
      "jeme.libr.fr" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          root = "/data/public/beatrice/website";
        }; # Static file serving
        locations."/files/" = {
          root = "/data/public/beatrice";
          extraConfig = ''
            autoindex on;
          '';
        };
      };
    };
  };

  #****************#
  #   MailServer   #
  #****************#

  mailserver = {
    enable = true;
    fqdn = "mail.libr.fr";
    domains = [
      "libr.fr"
      "michaelmercier.fr"
    ];

    x509.useACMEHost = "libr.fr";

    # Use `mkpasswd -m sha-512` to create the salted password
    accounts = {
      "mickours@libr.fr" = {
        hashedPasswordFile = "/data/keys/mickours-at-libr-dot-fr";
        aliases = [
          "michael.mercier@libr.fr"
          "michael@libr.fr"
          "m@libr.fr"
          "mm@libr.fr"
          "info@libr.fr"
          "postmaster@libr.fr"
          "abuse@libr.fr"
          "admin@libr.fr"
          "contact@libr.fr"
        ];
      };
      "marine.mercier@libr.fr" = {
        hashedPasswordFile = "/data/keys/marine-mercier-at-libr-dot-fr";
        aliases = [ "marine@libr.fr" ];
      };
      "simon.mercier@libr.fr" = {
        hashedPasswordFile = "/data/keys/simon-mercier-at-libr-dot-fr";
        aliases = [ "simon@libr.fr" ];
      };
      "me@michaelmercier.fr" = {
        hashedPasswordFile = "/data/keys/me-at-michaelmercier-dot-fr";
        catchAll = [ "michaelmercier.fr" ];
        aliases = [ "job@michaelmercier.fr" ];
      };
      "labelleverte@libr.fr" = {
        hashedPasswordFile = "/data/keys/labelleverte-at-libr-dot-fr";
        aliases = [ "lbv@libr.fr" ];
      };
      "nextcloud@libr.fr" = {
        hashedPasswordFile = "/data/keys/nextcloud-at-libr-dot-fr";
        aliases = [ "ne-pas-repondre@libr.fr" ];
      };
      "bitwarden@libr.fr" = {
        hashedPasswordFile = "/data/keys/bitwarden-at-libr-dot-fr";
        aliases = [ "ne-pas-repondre@libr.fr" ];
      };
    };

    # Use imap on port 993 and smtp on 587
    enableImap = true;
    enableImapSsl = true;
    # enableManageSieve = true;
    hierarchySeparator = "/";

    # Enable DKIM reporting
    dmarcReporting.enable = true;

    # manage data migration
    stateVersion = 4;

    # put everything in the /data folder to simplify backups
    storage.path = "/data/vmail";
    dkim.keyDirectory = "/data/dkim";
  };

  ##***************#
  ##   NextCloud   #
  ##***************#

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud34;
    home = "/data/nextcloud";
    hostName = "nextcloud.libr.fr";
    https = true;
    config.adminpassFile = "/data/admin_nextcloud";
    # DB config
    # config.dbtype = "sqlite";
    config.dbtype = "pgsql";
    config.dbhost = "/run/postgresql";

    # Forces Nextcloud to use HTTPS
    settings = {
      overwriteProtocol = "https";
      default_phone_region = "FR";

      log_type = "file";

      mail_domain = "libr.fr";
      mail_from_address = "ne-pas-repondre";
      mail_smtpmode = "smtp";
      mail_smtphost = "mail.libr.fr";
      mail_smtpport = 465;
      mail_smtpsecure = "ssl";
      mail_smtpauth = true;
      mail_smtpname = "nextcloud@libr.fr";
      mail_smtptimeout = 30;
      mail_smtpdebug = true;
      # WARNING smtp password is injected manually

      apps.memories.exiftool_no_local = true;
      # Fix memories place setup
      dbtableprefix = "oc_";

      # Serve the dlib models from the Nix store instead of having
      # `occ face:setup` download them into appdata at runtime. The app's
      # install() is a no-op once the files are there and ModelService skips
      # its mkdir on an existing directory, so a read-only path is fine.
      "facerecognition.model_path" = "${facerecognition.models}";

      # Ensure standard system binaries and procps are available
      path = with pkgs; [
        which
        procps
        coreutils
      ];

    };

    config.objectstore.s3 = {
      enable = true;
      region = "eu-west-3";
      key = "AKIAZFTZEYESUAQVO5MO";
      bucket = "nextcloud-libr-fr";
      secretFile = "/data/s3_nextcloud";
      # verify_bucket_exists = true;
      # region = "fr-par";
      # hostname = "s3.fr-par.scw.cloud";
      # key = "SCWM8NR3996ET9FMHQCC";
      # bucket = "primary0-nextcloud-libr-fr";
      # secretFile = "/data/s3_nextcloud_scw";
    };
    # For face recognition App
    phpExtraExtensions = all: [
      all.pdlib
      all.bz2
      all.apcu
    ];

    # Built from upstream master rather than the appstore: the latest release
    # (v0.9.70) is published for Nextcloud 31 only. Master declares NC 34, which
    # matches the package above. Unlike the previous bare fetchFromGitHub, this
    # derivation also builds the frontend, so the app's own settings pages work.
    extraApps.facerecognition = facerecognition;
    extraAppsEnable = true;
    # extraApps disables the appstore UI by default; keep it on so the other
    # appstore-installed apps (Memories, etc.) can still be managed/updated.
    appstoreEnable = true;
    maxUploadSize = "1G";
    fastcgiTimeout = 600;
    # Computed with https://spot13.com/pmcalculator/
    poolSettings = {
      "pm" = "dynamic";
      "pm.max_children" = "44";
      "pm.start_servers" = "11";
      "pm.min_spare_servers" = "11";
      "pm.max_spare_servers" = "33";
      "pm.max_requests" = "500";
    };
    phpOptions = {
      "opcache.interned_strings_buffer" = "32";
    };
  };

  services.postgresql = {
    # Copied & adapted from nixpkgs
    enable = true;
    identMap = ''
      nextcloud nextcloud nextcloud
      nextcloud root nextcloud
    '';
    authentication = ''
      local all nextcloud peer map=nextcloud
    '';
    ensureDatabases = [
      "nextcloud"
    ];
    ensureUsers = [
      {
        name = "nextcloud";
        ensureDBOwnership = true;
      }
    ];
    dataDir = "/data/psql/${config.services.postgresql.package.psqlSchema}";
  };
  services.postgresqlBackup = {
    enable = true;
    backupAll = true;
    location = "/data/psql-backups";
  };

  # Fix nextcloud memories indexing
  systemd.services.nextcloud-cron = {
    path = [
      (pkgs.perl.withPackages (ps: [ exiftool_13_44 ]))
      pkgs.procps
      pkgs.which
    ];
  };

  ## For backgroud job for face recognition
  systemd.timers."nextcloud-face-recognition" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      Unit = "nextcloud-face-recognition.service";
    };
  };
  systemd.services."nextcloud-face-recognition" = {
    script = ''
      set -eu
      /run/current-system/sw/bin/nextcloud-occ face:background_job -t 3600
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "nextcloud";
      LoadCredential = "s3_secret:/data/s3_nextcloud";
    };
    environment = {
      NEXTCLOUD_CONFIG_DIR = "/data/nextcloud/config";
    };
  };

  services.bgremove = {
    enable = true;
    host = "0.0.0.0"; # default 127.0.0.1
    port = 8081;
    openFirewall = true; # default false
    nginx = {
      enable = true;
      fqdn = "bgremove.libr.fr";
      # enableACME = true; # Let's Encrypt cert + force HTTPS (default false)
    };
  };

  services.vaultwarden = {
    enable = true;
    # Needed to enable postgresql
    package = pkgs.vaultwarden-postgresql;
    dbBackend = "postgresql";
    configureNginx = true;
    configurePostgres = true;
    domain = bitwardenFQDN;

    # in order to avoid having ADMIN_TOKEN in the nix store it can be also set with the help of an environment file
    # be aware that this file must be created by hand (or via secrets management like sops)
    #
    # Required variables;
    # SMTP_USERNAME=username
    # SMTP_PASSWORD=password
    environmentFile = "/data/vaultwarden/vaultwarden.env";
    config = {
      # Refer to https://github.com/dani-garcia/vaultwarden/blob/main/.env.template
      SIGNUPS_ALLOWED = false;

      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;
      ROCKET_LOG = "critical";

      # This example assumes a mailserver running on localhost,
      # thus without transport encryption.
      # If you use an external mail server, follow:
      #   https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration
      SMTP_HOST = "mail.libr.fr";
      SMTP_SECURITY = "force_tls";
      SMTP_FROM = "bitwarden@libr.fr";
      SMTP_FROM_NAME = "libr.fr Bitwarden server";
    };
  };

  #*************#
  #   Network   #
  #*************#
  networking = {
    firewall.allowedTCPPorts = [
      webPort
      webSslPort
    ];
  };

  #*************#
  # Admin tools #
  #*************#
  environment.systemPackages =

    with pkgs; [
      wget
      # for backups
      rsync
      borgbackup
      # For web site traffic analytics
      goaccess
      # Extra tools
      ripgrep
      neovim
      jq
      restic
      sqlite-interactive
      dig
      unixtools.netstat
      git
      sl
      # For nextcloud apps: Memories
      exiftool_13_44
      ffmpeg
    ];
}
