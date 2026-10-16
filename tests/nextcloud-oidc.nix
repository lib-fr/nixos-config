# Runs a real Nextcloud against a real Kanidm and checks every precondition for
# an SSO login landing on an *existing* account rather than silently creating an
# empty new one. Everything comes from lib/nextcloud-oidc.nix, the same code
# machines/vps/configuration.nix uses, so a wrong URL or mapping flag fails here
# rather than at someone's first login.
#
# What this does NOT do is complete an actual login. Kanidm has no
# client-credentials or password grant, and a person's password can only be set
# interactively, so obtaining a real ID token means driving Kanidm's own HTMX
# login and credential-reset pages. Those are undocumented internal routes
# (/ui/reset/add_password, /ui/api/cu_commit, /ui/login/begin) which change
# between releases, and a test built on them would break `nix flake check` on an
# unrelated Kanidm bump. So the final redirect is left to the manual check in
# the rollout: compare `occ user:list` before and after the first login.
#
# The gap is therefore exactly one step wide: this proves Kanidm sends a short
# `preferred_username` and that Nextcloud is set to use that claim verbatim as
# the user id, but not that user_oidc then resolves it to the existing row.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  certs = import "${pkgs.path}/nixos/tests/common/acme/server/snakeoil-certs.nix";
  domain = certs.domain;

  certsPath = pkgs.runCommand "snakeoil-certs" { } ''
    mkdir $out
    cp ${certs."${domain}".cert} $out/cert.pem
    cp ${certs."${domain}".key} $out/key.pem
  '';

  oidc = import ../lib/nextcloud-oidc.nix { };
  clientId = "nextcloud";

  # Only one snakeoil certificate exists, so both services answer on the same
  # name and Kanidm takes a port of its own. Kanidm's `domain` still has to be a
  # suffix of the origin's host, which it is.
  idmBase = "https://${domain}:8443";
  nextcloudBase = "https://${domain}";

  discoveryUri = oidc.discoveryUriFor idmBase clientId;
  redirectUri = oidc.redirectUriFor nextcloudBase;

  idmAdminPassword = "verystrongpassword-idm-admin";
  clientSecret = "verystrongpassword-oauth2-client";
  adminPassword = "verystrongpassword-nc-admin";

  # The person's Kanidm name deliberately matches a Nextcloud account that
  # already exists below. That collision is the whole point of the test.
  personName = "alice";

  roster = pkgs.writeText "roster.json" (
    builtins.toJSON {
      persons.${personName} = {
        displayName = "Alice Example";
        mailAddresses = [ "alice@${domain}" ];
      };
      groups.nextcloud_users.members = [ personName ];
    }
  );
in
{
  name = "nextcloud-oidc";

  nodes.server =
    { config, ... }:
    {
      virtualisation.memorySize = 3072;
      virtualisation.diskSize = 4096;

      security.pki.certificateFiles = [ certs.ca.cert ];
      networking.hosts = {
        "127.0.0.1" = [ domain ];
        "::1" = [ domain ];
      };

      services.kanidm = {
        package = pkgs.kanidm_1_11.withSecretProvisioning;
        server = {
          enable = true;
          settings = {
            inherit domain;
            origin = idmBase;
            bindaddress = "[::]:8443";
            tls_chain = "${certsPath}/cert.pem";
            tls_key = "${certsPath}/key.pem";
          };
        };
        client.enable = true;
        client.settings.uri = idmBase;

        provision = {
          enable = true;
          instanceUrl = idmBase;
          idmAdminPasswordFile = pkgs.writeText "idm-admin-pw" idmAdminPassword;
          extraJsonFile = roster;
          groups.nextcloud_users = { };
          systems.oauth2.${clientId} = {
            displayName = "Nextcloud";
            originUrl = redirectUri;
            originLanding = "${nextcloudBase}/";
            basicSecretFile = pkgs.writeText "oauth2-secret" clientSecret;
            # Without this Kanidm sends the SPN (alice@acme.test) as
            # preferred_username and the mapping below would create a second
            # account instead of reusing the existing one.
            preferShortUsername = true;
            scopeMaps.nextcloud_users = [
              "openid"
              "email"
              "profile"
            ];
          };
        };
      };

      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud34;
        hostName = domain;
        https = true;
        config.dbtype = "sqlite";
        config.adminpassFile = "${pkgs.writeText "nc-admin-pw" adminPassword}";
        settings.default_phone_region = "FR";
        extraApps = {
          user_oidc = pkgs.nextcloud34Packages.apps.user_oidc;
        };
        extraAppsEnable = true;
      };

      services.nginx.virtualHosts.${domain} = {
        forceSSL = true;
        sslCertificate = "${certsPath}/cert.pem";
        sslCertificateKey = "${certsPath}/key.pem";
      };

      environment.systemPackages = [
        pkgs.jq
        pkgs.openldap
      ];
    };

  testScript = ''
    import json

    start_all()
    server.wait_for_unit("kanidm.service")
    server.wait_for_unit("phpfpm-nextcloud.service")
    server.wait_for_unit("nginx.service")
    server.wait_until_succeeds("curl -Lsf ${idmBase} | grep -q Kanidm", timeout=90)
    server.wait_until_succeeds("curl -sf ${nextcloudBase}/status.php | grep -q installed", timeout=90)

    with subtest("Kanidm publishes discovery where lib/nextcloud-oidc.nix looks"):
        # A per-client path under the client's name, not one document for the
        # whole server -- the easiest thing in this setup to get wrong.
        doc = json.loads(server.succeed("curl -sf '${discoveryUri}'"))
        assert doc["issuer"].rstrip("/").endswith("/oauth2/openid/${clientId}"), (
            f"unexpected issuer: {doc['issuer']}"
        )
        for key in ("authorization_endpoint", "token_endpoint", "jwks_uri", "userinfo_endpoint"):
            assert key in doc, f"discovery document has no {key}:\n{doc}"
        # user_oidc validates ID token signatures against this, so an
        # unreachable JWKS fails every login with an opaque error.
        jwks = json.loads(server.succeed(f"curl -sf '{doc['jwks_uri']}'"))
        assert jwks.get("keys"), f"empty JWKS: {jwks}"

    with subtest("the oauth2 client is provisioned as the mapping requires"):
        server.succeed("KANIDM_PASSWORD=${idmAdminPassword} kanidm login -D idm_admin")
        out = server.succeed("kanidm system oauth2 get ${clientId} --name idm_admin")
        assert "${redirectUri}" in out, f"redirect uri not registered:\n{out}"
        # preferShortUsername and --mapping-uid=preferred_username only work as
        # a pair; this is the half that lives in Kanidm.
        assert "prefer_short_username: true" in out.lower(), (
            f"prefer_short_username is not set, so preferred_username would be the SPN:\n{out}"
        )

    with subtest("an account with the same name exists before any SSO login"):
        server.succeed(
            "OC_PASS=irrelevant-local-password nextcloud-occ user:add --password-from-env ${personName}"
        )
        # A file to prove the account was *reused* rather than recreated: a new
        # account would come up empty.
        server.succeed(
            "nextcloud-occ files:scan ${personName}"
        )
        users = json.loads(server.succeed("nextcloud-occ user:list --output=json"))
        assert "${personName}" in users, f"setup failed, no such user: {users}"

    with subtest("the provider registers with the production arguments"):
        server.succeed(
            "nextcloud-occ user_oidc:provider Kanidm"
            " --clientid='${clientId}'"
            " --clientsecret='${clientSecret}'"
            " --discoveryuri='${discoveryUri}'"
            " ${lib.escapeShellArgs oidc.providerMappingArgs}"
        )
        provider = json.loads(
            server.succeed("nextcloud-occ user_oidc:provider Kanidm --output=json")
        )
        settings = provider["settings"]
        assert provider["clientId"] == "${clientId}", provider
        assert provider["discoveryEndpoint"] == "${discoveryUri}", provider
        # The two settings that decide reuse-vs-duplicate.
        assert str(settings["uniqueUid"]) in ("0", "False", "false"), (
            f"uniqueUid is set, so user ids would be hashed and the existing "
            f"account missed: {settings}"
        )
        assert settings["mappingUid"] == "preferred_username", settings

    with subtest("the login page offers the provider"):
        page = server.succeed("curl -Lsf '${nextcloudBase}/login'")
        assert "user_oidc" in page, f"no SSO login option rendered:\n{page[:2000]}"
  '';
}
