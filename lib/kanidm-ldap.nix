# How Kanidm's LDAP interface names things.
#
# These two strings were the only part of the mail integration that could not be
# checked by building the configuration: they have to match what a *running*
# Kanidm actually returns. They live here rather than inline so that
# tests/kanidm-ldap.nix exercises the very same code against a real server --
# a copy in the test would only prove the copy right.
{ lib }:
rec {
  # Kanidm derives its LDAP base DN from the domain it manages, one `dc=`
  # component per label. Changeable with `kanidm system domain set-ldap-basedn`,
  # which we do not do.
  #
  #   baseDNOf "idm.example.com" == "dc=idm,dc=example,dc=com"
  baseDNOf =
    domain: lib.concatMapStringsSep "," (component: "dc=${component}") (lib.splitString "." domain);

  # Group membership is rendered as the group's full DN, built from its SPN
  # rather than its bare name:
  #
  #   groupDNOf "idm.example.com" "mail_users"
  #     == "spn=mail_users@idm.example.com,dc=idm,dc=example,dc=com"
  groupDNOf = domain: group: "spn=${group}@${domain},${baseDNOf domain}";
}
