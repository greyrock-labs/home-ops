from pathlib import Path

# Kanidm OIDC. kaniop writes the client credentials to the
# netbox-kanidm-oauth2-credentials Secret, mounted at /run/secrets/oidc.
SOCIAL_AUTH_OIDC_OIDC_ENDPOINT = "https://idm.greyrock.io/oauth2/openid/netbox"
SOCIAL_AUTH_OIDC_KEY = Path("/run/secrets/oidc/CLIENT_ID").read_text().strip()
SOCIAL_AUTH_OIDC_SECRET = Path("/run/secrets/oidc/CLIENT_SECRET").read_text().strip()
# Kanidm signs ID tokens with ES256 unless legacy RS256 is enabled on the client.
SOCIAL_AUTH_OIDC_JWT_ALGORITHMS = ["ES256"]
SOCIAL_AUTH_OIDC_SCOPE = ["openid", "profile", "email"]
SOCIAL_AUTH_OIDC_USE_PKCE = True
SOCIAL_AUTH_REDIRECT_IS_HTTPS = True
SOCIAL_AUTH_BACKEND_ATTRS = {"oidc": ("Kanidm", "login")}
