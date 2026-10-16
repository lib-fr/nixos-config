{
  config,
  lib,
  pkgs,
  leProjetDeVie,
  ...
}:
let
  webPort = 80;
  webSslPort = 443;
  myKeys = [
    ../../keys/id_rsa_oursbook.pub
    ../../keys/id_rsa_vps_passless.pub
  ];
  bitwardenFQDN = "bitwarden.libr.fr";
  nextcloudFQDN = "nextcloud.libr.fr";
  idmFQDN = "idm.libr.fr";
  # Kanidm derives its LDAP base DN from the domain it manages, which must be a
  # suffix of the origin's host -- so `idm.libr.fr`, not `libr.fr`.
  idmBaseDN = "dc=idm,dc=libr,dc=fr";
  # Kanidm renders group membership as the group's full DN, e.g.
  # `memberof: spn=mail_users@idm.libr.fr,dc=idm,dc=libr,dc=fr`. Gating the mail
  # filters on it means being a person in Kanidm is not by itself enough to
  # collect mail -- only members of `mail_users` are.
  mailGroupDN = "spn=mail_users@${idmFQDN},${idmBaseDN}";

  # Whether Dovecot/Postfix authenticate against Kanidm over LDAP.
  #
  # This has to stay false until `/data/keys/kanidm-mailserver-token` exists,
  # because Dovecot loads it as a systemd credential and refuses to start
  # otherwise -- and the token can only be minted once Kanidm is running:
  #
  #   kanidm login --name idm_admin
  #   kanidm service-account create mailserver "Mail Server" --name idm_admin
  #   kanidm group add-members idm_people_pii_read mailserver --name idm_admin
  #   kanidm service-account api-token generate --name idm_admin \
  #       mailserver dovecot --read-only
  #   # write the printed token, with no trailing newline, to
  #   # /data/keys/kanidm-mailserver-token (chmod 400), then flip this to true
  #
  # Existing `mailserver.accounts` keep working either way: simple-nixos-mailserver
  # gives declarative users priority over LDAP ones, so mailboxes can be moved
  # across one at a time rather than in a big bang.
  mailUsesLdap = false;

  facerecognition = pkgs.callPackage ../../pkgs/nextcloud-app-facerecognition { };
in
{
  system.stateVersion = "26.05";
  nix.settings.trusted-users = [ "@wheel" ];

  # Needed for rsync backups
  programs.zsh.enable = true;

  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    # Common config
    ../../modules/common.nix
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
      # Dynamic keys cannot be repeated across attribute paths, so these are
      # merged into one attrset rather than written as two dotted assignments.
      "${nextcloudFQDN}" = {
        forceSSL = true;
        enableACME = true;
      };

      "bgremove.libr.fr".forceSSL = true;
      "bgremove.libr.fr".enableACME = true;

      "${bitwardenFQDN}".enableACME = true;

      # Kanidm speaks HTTPS on its own socket (it has no plaintext mode, and it
      # needs a real certificate for LDAPS anyway), so this proxies TLS to TLS.
      # nginx does not verify the backend certificate by default, which is what
      # we want for a 127.0.0.1 hop where the name would never match.
      "${idmFQDN}" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "https://127.0.0.1:8443";
          proxyWebsockets = true;
        };
      };

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

  #*******************************#
  #   Kanidm -- SSO / directory   #
  #*******************************#

  # Kanidm is both the OIDC provider (Nextcloud, Vaultwarden) and the LDAP
  # directory (Dovecot, Postfix). It terminates TLS itself on both sockets, so
  # it reads the very same ACME certificate nginx serves for idm.libr.fr:
  # ownership of that cert moves to the kanidm group and nginx is added to it,
  # since both daemons need to read the key.
  security.acme.certs."${idmFQDN}" = {
    group = "kanidm";
    reloadServices = [ "kanidm.service" ];
  };
  users.users.nginx.extraGroups = [ "kanidm" ];

  # The Nextcloud client secret is read by two different daemons: kanidm (which
  # pushes it as the oauth2 basic secret) and nextcloud-setup (which hands it to
  # user_oidc). A shared group beats making it world-readable:
  #   chown root:oidc-secrets /data/keys/kanidm-oauth2-nextcloud
  #   chmod 440            /data/keys/kanidm-oauth2-nextcloud
  users.groups.oidc-secrets.members = [
    "kanidm"
    "nextcloud"
  ];

  # Both sockets listen on loopback only. Resolving the public name to
  # 127.0.0.1 lets Dovecot reach LDAPS and Nextcloud reach the discovery
  # document over the loopback while still presenting -- and validating -- a
  # certificate that matches the name.
  networking.hosts."127.0.0.1" = [ idmFQDN ];

  services.kanidm = {
    # `withSecretProvisioning` carries the out-of-tree patches that let the
    # oauth2 basic secrets and the idm_admin password below be provisioned from
    # files instead of being generated on every restart.
    package = pkgs.kanidm_1_11.withSecretProvisioning;

    server = {
      enable = true;
      settings = {
        domain = idmFQDN;
        origin = "https://${idmFQDN}";
        bindaddress = "127.0.0.1:8443";
        ldapbindaddress = "127.0.0.1:3636";
        tls_chain = "/var/lib/acme/${idmFQDN}/fullchain.pem";
        tls_key = "/var/lib/acme/${idmFQDN}/key.pem";
        # Sits behind nginx, so take the client address from the proxy.
        trust_x_forward_for = true;
        online_backup = {
          path = "/data/kanidm-backups";
          versions = 7;
        };
      };
    };

    # kanidm is also used as a client on the machine, to run `kanidm login`,
    # mint the mailserver API token, and hand out credential reset links.
    client.enable = true;
    client.settings.uri = "https://${idmFQDN}";

    provision = {
      enable = true;
      # Talks to the loopback socket directly, whose certificate is valid for
      # idmFQDN rather than for `localhost`.
      instanceUrl = "https://${idmFQDN}";
      acceptInvalidCerts = false;

      # Without this the idm_admin password is reset on every restart, which
      # would invalidate the credential-reset workflow mid-migration.
      idmAdminPasswordFile = "/data/keys/kanidm-idm-admin-password";

      groups = {
        nextcloud_users = { };
        nextcloud_admins = { };
        vaultwarden_users = { };
        mail_users = { };
      };

      # Names and addresses are personal data, so the roster is not in this
      # repo: it is merged in at runtime from a file on the server, using
      # kanidm-provision's own JSON schema. `persons.example.json` documents
      # the format. The module bind-mounts this path read-only into the unit,
      # which runs as `kanidm`, so:
      #   chown kanidm:kanidm /data/keys/kanidm-persons.json && chmod 400 it
      #
      # Two things to know about the merge. It is a deep merge that appends
      # lists, so the empty `members` declared above are filled in from the
      # file rather than replaced. And because `autoRemove` is on, whatever
      # this file says is authoritative: a person dropped from it is deleted
      # from Kanidm on the next restart. A missing file fails the unit instead,
      # which is the safer failure of the two.
      #
      # Setting this also switches off the module's group assertions, so a
      # misspelled group name in the file creates a stray group rather than
      # failing evaluation. Check `kanidm group list` after adding someone.
      extraJsonFile = "/data/keys/kanidm-persons.json";

      # Credentials are still never provisioned -- Kanidm has no way to set a
      # password. Each new person needs one reset link:
      #   kanidm person credential create-reset-token <name> --name idm_admin

      systems.oauth2 = {
        nextcloud = {
          displayName = "Nextcloud";
          originUrl = "https://${nextcloudFQDN}/apps/user_oidc/code";
          originLanding = "https://${nextcloudFQDN}/";
          basicSecretFile = "/data/keys/kanidm-oauth2-nextcloud";
          # user_oidc maps accounts on `preferred_username`; the short name
          # matches the existing Nextcloud user IDs, whereas the default SPN
          # (`<name>@idm.libr.fr`) would create duplicates.
          preferShortUsername = true;
          scopeMaps.nextcloud_users = [
            "openid"
            "email"
            "profile"
          ];
        };

        vaultwarden = {
          displayName = "Vaultwarden";
          originUrl = "https://${bitwardenFQDN}/identity/connect/oidc-signin";
          originLanding = "https://${bitwardenFQDN}/";
          basicSecretFile = "/data/keys/kanidm-oauth2-vaultwarden";
          preferShortUsername = true;
          scopeMaps.vaultwarden_users = [
            "openid"
            "email"
            "profile"
          ];
        };
      };
    };
  };

  # The certificate has to exist before kanidm can bind its sockets, and the
  # provisioning step that runs after startup reaches the API back through
  # nginx, so order after both. acme-<cert> drops a self-signed placeholder on a
  # fresh machine, and the reloadServices above restarts kanidm once the real
  # certificate is issued.
  systemd.services.kanidm = {
    after = [
      "acme-${idmFQDN}.service"
      "nginx.service"
    ];
    wants = [ "acme-${idmFQDN}.service" ];
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

    # IMAP and SMTP cannot do an OIDC redirect, so mail clients keep using a
    # password -- what changes is where that password lives. Dovecot performs an
    # authentication bind against Kanidm (`attributes.password = null`), which
    # means Kanidm never hands out a hash and the person must be a POSIX account
    # with a POSIX password set:
    #
    #   kanidm person posix set <name> --name idm_admin
    #   kanidm person posix set-password <name>          # as the person
    #   kanidm system domain set-ldap-allow-unix-password-bind true --name admin
    #
    # That POSIX password is deliberately distinct from the person's SSO
    # credential: it is the mail app-password, and it is the only thing an
    # IMAP client ever sees.
    ldap = {
      enable = mailUsesLdap;
      uris = [ "ldaps://${idmFQDN}:3636" ];
      bind = {
        # Kanidm authenticates service accounts by API token rather than by
        # password: the literal DN `dn=token`, with the token as the secret.
        dn = "dn=token";
        passwordFile = "/data/keys/kanidm-mailserver-token";
      };
      base = idmBaseDN;
      scope = "sub";

      # The default pass filter is `<username attr>=%{user}`, which would let
      # someone log in with their bare account name. Everyone authenticates
      # with a full address today, and Postfix's sender check below only
      # recognises addresses, so accept nothing else -- a short-name login
      # would authenticate but then be unable to send.
      dovecot.passFilter = "(&(memberof=${mailGroupDN})(mail=%{user}))";
      dovecot.userFilter = "(mail=%{user})";
      # Which addresses Postfix accepts for delivery at all.
      postfix.filter = "(&(memberof=${mailGroupDN})(mail=%s))";

      attributes = {
        # Dovecot derives the mailbox path from this, so it must be the one
        # attribute that survives a rename: Kanidm's entry UUID.
        uuid = "entryuuid";
        # Only ever used as Postfix's `result_attribute`, which feeds
        # smtpd_sender_login_maps. `mail` is multi-valued in Kanidm, so a lookup
        # returns every address the person owns and each of their aliases is
        # accepted as a From: -- the LDAP equivalent of the `vaccounts` map that
        # the declarative accounts get.
        username = "mail";
        mail = "mail";
        # null keeps Dovecot on authentication binds -- see above.
        password = null;
      };
    };
  };

  ##***************#
  ##   NextCloud   #
  ##***************#

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud34;
    home = "/data/nextcloud";
    hostName = nextcloudFQDN;
    https = true;
    config.adminpassFile = "/data/admin_nextcloud";
    # DB config
    # config.dbtype = "sqlite";
    config.dbtype = "pgsql";
    config.dbhost = "/run/postgresql";

    # Forces Nextcloud to use HTTPS
    settings = {
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

      # Fix memories place setup
      dbtableprefix = "oc_";

      # Serve the dlib models from the Nix store instead of having
      # `occ face:setup` download them into appdata at runtime. The app's
      # install() is a no-op once the files are there and ModelService skips
      # its mkdir on an existing directory, so a read-only path is fine.
      "facerecognition.model_path" = "${facerecognition.models}";

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

    extraApps = {
      # Built from upstream master rather than the appstore: the latest release
      # (v0.9.70) is published for Nextcloud 31 only. Master declares NC 34,
      # which matches the package above. Unlike the previous bare
      # fetchFromGitHub, this derivation also builds the frontend, so the app's
      # own settings pages work.
      inherit facerecognition;
      # The appstore build ships PAR-packed exiftool binaries that it copies to
      # /tmp and executes; those ELFs need /lib64/ld-linux-x86-64.so.2 and
      # cannot run on NixOS. It also shells out to `perl`, `which`, `ffmpeg`
      # and go-vod through PATH, which is empty in the systemd units that run
      # occ/cron. This package patches all of those to absolute store paths
      # (and rewrites EXIFTOOL_VER to match nixpkgs' exiftool), so nothing
      # depends on PATH any more. Same version (8.1.0) as the appstore build.
      memories = pkgs.nextcloud34Packages.apps.memories;
      # OIDC login against Kanidm. Configured below, in nextcloud-setup's
      # postStart, because the provider has to be registered with `occ`.
      user_oidc = pkgs.nextcloud34Packages.apps.user_oidc;
    };
    extraAppsEnable = true;
    # extraApps disables the appstore UI by default; keep it on so the other
    # appstore-installed apps can still be managed/updated.
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

  # files_lock ships lock_timeout = -1 (infinite). Text leaks a lock whenever an
  # editing session dies (nextcloud/text#9042), and with an infinite timeout
  # LockService::getDeprecatedLocks() returns nothing, so the cleanup cron never
  # purges it: every later write to that file gets HTTP 423 forever -- which is
  # how the Notes Android app silently stops syncing (nextcloud/notes#1940).
  # 24h rather than something short because the purge filters on the lock's
  # `creation` and LocksRequest::update() never refreshes it, so an actively
  # extended lock is still purged on its original creation time.
  systemd.services.nextcloud-setup = {
    # The oauth2 client only exists once kanidm's provisioning ExecStartPost has
    # run, and user_oidc fetches the discovery document when the provider is
    # registered.
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];

    postStart = ''
      ${lib.getExe config.services.nextcloud.occ} config:app:set files_lock lock_timeout --value 1440

      # Idempotent: `user_oidc:provider <id>` updates the provider when one with
      # that identifier already exists. The secret is passed by path so it never
      # reaches the Nix store or the process table.
      #
      # `--unique-uid=0` is what makes this a migration rather than a fresh
      # start: with it set, user_oidc uses the `preferred_username` claim
      # verbatim as the Nextcloud user ID instead of hashing it together with
      # the provider, so `mickours` logs back into the existing account and its
      # files, rather than into an empty one.
      ${lib.getExe config.services.nextcloud.occ} user_oidc:provider Kanidm \
        --clientid="nextcloud" \
        --clientsecret-file="/data/keys/kanidm-oauth2-nextcloud" \
        --discoveryuri="https://${idmFQDN}/oauth2/openid/nextcloud/.well-known/openid-configuration" \
        --endsessionendpointuri="https://${idmFQDN}/ui/logout" \
        --scope="openid email profile" \
        --unique-uid=0 \
        --mapping-uid="preferred_username" \
        --mapping-display-name="name" \
        --mapping-email="email"

      # Keep the plain login form reachable alongside SSO during the migration;
      # it is also the way back in if Kanidm is ever down.
      ${lib.getExe config.services.nextcloud.occ} config:app:set user_oidc allow_multiple_user_backends --value=1
    '';
  };

  # Units without an explicit `path` run with systemd's compiled-in default
  # PATH, which on NixOS holds almost nothing, so anything shelling out to
  # `which`, `ps`, ... fails -- e.g. Memories' BinExt::pkill() from
  # nextcloud-cron, or from the transient units nextcloud-occ spawns through
  # systemd-run to load its credentials. This has to be the manager's
  # DefaultEnvironment: systemd.globalEnvironment only merges into the
  # Environment= of NixOS-declared units, so systemd-run transients miss it.
  # Same PATH the nextcloud module gives its php-fpm pool; units setting their
  # own `path` still win.
  systemd.settings.Manager.DefaultEnvironment = "PATH=/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin";

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
    port = 8001; # le-projet-de-vie's gunicorn hardcodes 127.0.0.1:8000
    nginx = {
      enable = true;
      fqdn = "bgremove.libr.fr";
      # enableACME = true; # Let's Encrypt cert + force HTTPS (default false)
    };
    maxConcurrency = 1;
    maxPixels = 12000000;
    maxQueue = 4;
    maxUploadMB = 15;
    threads = 2; # match your vCPU count

    memoryHigh = "1400M";
    memoryMax = "1600M";
    memorySwapMax = "512M";
  };

  services.repartition-classes = {
    enable = true;
    # host = "127.0.0.1" et port = 5000 par défaut : l'application n'est
    # joignable qu'à travers le reverse proxy, donc pas d'openFirewall.
    nginx = {
      enable = true;
      virtualHost = "repartition.libr.fr";
      # enableACME et forceSSL sont activés par défaut
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
    # SSO_CLIENT_SECRET=<contents of /data/keys/kanidm-oauth2-vaultwarden>
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

      # SSO has been part of mainline Vaultwarden since 1.34, so this needs no
      # patched build. SSO_CLIENT_SECRET lives in the environmentFile above.
      SSO_ENABLED = true;
      SSO_AUTHORITY = "https://${idmFQDN}/oauth2/openid/vaultwarden";
      SSO_CLIENT_ID = "vaultwarden";
      # `openid` is added by the openidconnect crate itself -- listing it here
      # too would send it twice. This matches upstream's default.
      SSO_SCOPES = "email profile";
      # The vault stays encrypted under the master password regardless of how
      # the user authenticates, so existing accounts are adopted by matching the
      # e-mail address from Kanidm -- no re-encryption, no data loss.
      SSO_SIGNUPS_MATCH_EMAIL = true;
      # Leave the master-password login path open: SSO_ONLY would lock everyone
      # out if Kanidm were unavailable. Worth revisiting once this has settled.
      SSO_ONLY = false;
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
      exiftool
      ffmpeg
      # ldapsearch/ldapwhoami, to debug the Kanidm LDAP interface
      openldap
    ];
}
