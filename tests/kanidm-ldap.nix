# Checks the part of the mail integration that building the configuration
# cannot: the strings in lib/kanidm-ldap.nix have to match what a *running*
# Kanidm returns over LDAP. Everything here uses that same library and the same
# filter expressions as machines/vps/configuration.nix, so a format change
# upstream fails this test rather than mail on the server.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  certs = import "${pkgs.path}/nixos/tests/common/acme/server/snakeoil-certs.nix";
  domain = certs.domain;

  # Copied into the store to dodge the test VM's mount namespacing, as upstream's
  # own kanidm tests do.
  certsPath = pkgs.runCommand "snakeoil-certs" { } ''
    mkdir $out
    cp ${certs."${domain}".cert} $out/cert.pem
    cp ${certs."${domain}".key} $out/key.pem
  '';

  kanidmLdap = import ../lib/kanidm-ldap.nix { inherit lib; };
  baseDN = kanidmLdap.baseDNOf domain;
  mailGroupDN = kanidmLdap.groupDNOf domain "mail_users";

  # Byte-for-byte the expressions machines/vps/configuration.nix hands to
  # simple-nixos-mailserver, with Dovecot's `%{user}` and Postfix's `%s` filled
  # in the way those daemons fill them.
  passFilterFor = user: "(&(memberof=${mailGroupDN})(mail=${user}))";
  postfixFilterFor = addr: "(&(memberof=${mailGroupDN})(mail=${addr}))";

  idmAdminPassword = "verystrongpassword-idm-admin";

  # Deliberately provisioned through extraJsonFile rather than the NixOS
  # options, because that is how the real deployment does it -- and because this
  # is kanidm-provision's own schema, where membership lives under
  # groups.<name>.members and a person has no `groups` field at all.
  roster = pkgs.writeText "roster.json" (
    builtins.toJSON {
      persons = {
        alice = {
          displayName = "Alice Example";
          mailAddresses = [
            "alice@${domain}"
            "alice.alias@${domain}"
          ];
        };
        # Has a mailbox address but is NOT in mail_users: the filters must reject
        # this one, otherwise the group gate is decorative.
        bob = {
          displayName = "Bob Example";
          mailAddresses = [ "bob@${domain}" ];
        };
      };
      groups.mail_users.members = [ "alice" ];
    }
  );
in
{
  name = "kanidm-ldap";

  nodes.server =
    { ... }:
    {
      services.kanidm = {
        package = pkgs.kanidm_1_11.withSecretProvisioning;

        server = {
          enable = true;
          settings = {
            inherit domain;
            origin = "https://${domain}";
            bindaddress = "[::]:443";
            ldapbindaddress = "[::]:636";
            tls_chain = "${certsPath}/cert.pem";
            tls_key = "${certsPath}/key.pem";
          };
        };

        client.enable = true;
        client.settings.uri = "https://${domain}";

        provision = {
          enable = true;
          instanceUrl = "https://${domain}";
          idmAdminPasswordFile = pkgs.writeText "idm-admin-pw" idmAdminPassword;
          extraJsonFile = roster;
          # Declared empty here and filled in from the roster by the yq merge,
          # exactly as in the real configuration.
          groups.mail_users = { };
        };
      };

      security.pki.certificateFiles = [ certs.ca.cert ];
      environment.systemPackages = [ pkgs.openldap ];

      networking.hosts = {
        "127.0.0.1" = [ domain ];
        "::1" = [ domain ];
      };
    };

  testScript = ''
    import re

    start_all()
    server.wait_for_unit("kanidm.service")
    server.wait_until_succeeds("curl -Lsf https://${domain} | grep -q Kanidm", timeout=90)

    # Mint the service-account token the way the deployment runbook says to, so
    # the runbook is covered too and not just the filters.
    server.succeed("KANIDM_PASSWORD=${idmAdminPassword} kanidm login -D idm_admin")
    server.succeed(
        "kanidm service-account create mailserver 'Mail Server' idm_admins --name idm_admin"
    )
    server.succeed("kanidm group add-members idm_people_pii_read mailserver --name idm_admin")

    raw = server.succeed(
        "kanidm service-account api-token generate --name idm_admin mailserver dovecot"
    )
    # The token is a JWS in compact form; grab it without depending on how the
    # CLI decorates its output.
    match = re.search(r"[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}", raw)
    assert match, f"no api token in CLI output:\n{raw}"
    token = match.group(0)

    def ldapsearch(filt, attrs=""):
        return server.succeed(
            "ldapsearch -LLL -H ldaps://${domain}:636 "
            f"-b '${baseDN}' -D 'dn=token' -w '{token}' -x '{filt}' {attrs}"
        )

    with subtest("the service account can bind with dn=token"):
        who = server.succeed(
            f"ldapwhoami -H ldaps://${domain}:636 -D 'dn=token' -w '{token}' -x"
        )
        assert "mailserver" in who, f"unexpected bind identity: {who!r}"

    with subtest("memberof is rendered as the DN lib/kanidm-ldap.nix builds"):
        out = ldapsearch("(name=alice)", "memberof")
        assert "${mailGroupDN}" in out, (
            "group DN format differs from lib/kanidm-ldap.nix.\n"
            "expected: ${mailGroupDN}\ngot:\n" + out
        )

    with subtest("the attributes the mailserver config names all exist"):
        out = ldapsearch("(name=alice)", "entryuuid mail name")
        low = out.lower()
        for attr in ("entryuuid:", "mail:", "name:"):
            assert attr in low, f"missing {attr} in:\n{out}"
        # Dovecot derives the mailbox path from entryuuid, so an empty or
        # non-unique value would quietly put users in the same directory.
        uuid = [
            line.split(":", 1)[1].strip()
            for line in out.splitlines()
            if line.lower().startswith("entryuuid:")
        ][0]
        assert len(uuid) == 36, f"entryuuid is not a uuid: {uuid!r}"

    with subtest("Dovecot's pass filter matches a mail_users member"):
        # Both the primary address and an alias must authenticate, since `mail`
        # is multi-valued and people log in with whichever they were given.
        out = ldapsearch("${passFilterFor "alice@${domain}"}")
        assert "dn:" in out, f"pass filter returned nothing for the primary address:\n{out}"
        out = ldapsearch("${passFilterFor "alice.alias@${domain}"}")
        assert "dn:" in out, f"pass filter returned nothing for an alias:\n{out}"

    with subtest("the group gate actually excludes a non-member"):
        out = ldapsearch("${passFilterFor "bob@${domain}"}")
        assert "dn:" not in out, f"group gate leaked a non-member:\n{out}"
        # ... and bob is findable without the gate, which proves it was the
        # memberof clause that excluded him and not a typo in the address.
        out = ldapsearch("(mail=bob@${domain})")
        assert "dn:" in out, f"bob is unexpectedly absent entirely:\n{out}"

    with subtest("Postfix's lookup returns every sender identity"):
        # result_attribute is `mail`, so Postfix must get every address alice
        # owns -- that is what lets her aliases pass smtpd_sender_login_maps.
        out = ldapsearch("${postfixFilterFor "alice.alias@${domain}"}", "mail")
        assert "alice@${domain}" in out and "alice.alias@${domain}" in out, (
            "sender-login lookup did not return all owned addresses:\n" + out
        )
  '';
}
