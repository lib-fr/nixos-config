# The URLs and mapping settings that wire Nextcloud's user_oidc to Kanidm.
#
# Here rather than inline for the same reason as kanidm-ldap.nix: these are
# claims about what another system exposes, so tests/nextcloud-oidc.nix
# exercises this very code instead of a copy of it. Both take a base URL rather
# than a hostname so the test can point them at its own port.
{ }:
{
  # Kanidm publishes one discovery document per oauth2 client, under the
  # client's name -- not a single document for the whole server. Getting this
  # path wrong is silent until someone tries to log in.
  discoveryUriFor =
    issuerBase: clientId: "${issuerBase}/oauth2/openid/${clientId}/.well-known/openid-configuration";

  # Where user_oidc receives the authorization code. Must match the oauth2
  # client's originUrl in Kanidm exactly.
  redirectUriFor = nextcloudBase: "${nextcloudBase}/apps/user_oidc/code";

  # `--unique-uid=0` is what makes this a migration rather than a fresh start:
  # with it set, user_oidc uses the `preferred_username` claim verbatim as the
  # Nextcloud user ID instead of hashing it together with the provider, so an
  # existing account and its files are reused. Kanidm only sends a short name
  # there when the client has `preferShortUsername` set, so the two settings
  # have to be changed together.
  providerMappingArgs = [
    "--scope=openid email profile"
    "--unique-uid=0"
    "--mapping-uid=preferred_username"
    "--mapping-display-name=name"
    "--mapping-email=email"
  ];
}
