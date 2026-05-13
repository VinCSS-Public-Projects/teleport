# VinCSS SSO connectors

Teleport ships two VinCSS presets that work in the OSS build:

| Preset       | Resource kind | Sub-kind      | What it is                                                  |
| ------------ | ------------- | ------------- | ----------------------------------------------------------- |
| VinCSS OAuth2 | `github`      | `vincss`      | OAuth2 + custom `/api/user` (GitHub-style claims model)     |
| VinCSS OIDC   | `oidc`        | `vincss_oidc` | Standards-compliant OIDC: discovery, JWKS, ID token verify  |

Pick OIDC if your VinCSS deployment exposes a standard OIDC issuer (`/.well-known/openid-configuration` + JWKS). Pick OAuth2 only if the deployment exposes the legacy `/api/user` shape described below.

---

## VinCSS OAuth2 connector (sub_kind: vincss)

VinCSS OAuth2 is supported as a preset of the GitHub OAuth2 connector. It reuses the GitHub connector's resource kind, storage, and login flow, with three differences:

1. The connector spec carries `sub_kind: vincss`.
2. Endpoint URLs and (optionally) OAuth/API paths are read from the connector spec or environment variables — they are not pinned to `github.com`.
3. VinCSS exposes a single `/api/user` endpoint that returns the user's group membership inline as `teleportGroup []string`. There is no separate teams API. The connector synthesizes group entries under a fixed organization name (`vincss`) so existing `teams_to_roles` mappings work unchanged.

### Auth process environment

Set these on the Teleport auth process before starting it. The endpoint URLs are mandatory; the path overrides are only needed if the VinCSS deployment diverges from the defaults baked into the code.

| Variable                            | Required | Default            | Purpose                                                 |
| ----------------------------------- | -------- | ------------------ | ------------------------------------------------------- |
| `TELEPORT_VINCSS_ENDPOINT_URL`      | yes      | (none)             | Base URL serving the OAuth2 authorize / token endpoints |
| `TELEPORT_VINCSS_API_ENDPOINT_URL`  | yes      | (none)             | Base URL serving the user-info API                      |
| `TELEPORT_VINCSS_AUTH_PATH`         | no       | `oauth2/authorize` | Override the OAuth2 authorize path                      |
| `TELEPORT_VINCSS_TOKEN_PATH`        | no       | `oauth2/token`     | Override the OAuth2 token-exchange path                 |
| `TELEPORT_VINCSS_USER_PATH`         | no       | `api/user`         | Override the user-info API path                         |

The connector spec fields `endpoint_url` and `api_endpoint_url` take precedence over the env vars when set.

### Example connector

Save as `vincss-connector.yaml` and apply with `tctl create -f vincss-connector.yaml`.

```yaml
kind: github
sub_kind: vincss
version: v3
metadata:
  name: vincss
spec:
  # OAuth2 client credentials issued by the VinCSS IdP.
  client_id: <vincss-client-id>
  client_secret: <vincss-client-secret>

  # Proxy URL that VinCSS redirects the browser to after the user
  # authorizes the request. This path is the same as for GitHub SSO.
  redirect_url: https://<proxy-public-addr>/v1/webapi/github/callback

  # Optional: button label shown on the login screen.
  display: VinCSS

  # Optional: pin endpoints in the spec instead of using env vars.
  # endpoint_url: https://sso.vincss.example.com
  # api_endpoint_url: https://api.vincss.example.com

  # Map VinCSS teleportGroup values to Teleport roles.
  # `organization` must be the literal string "vincss" — that is the
  # synthetic organization the connector groups all teleportGroup
  # entries under.
  teams_to_roles:
    - organization: vincss
      team: admins
      roles: [access, editor, auditor]
    - organization: vincss
      team: developers
      roles: [access]
```

### Expected VinCSS API response

`GET <api_endpoint_url>/api/user` (with `Authorization: token <access_token>`) should return:

```json
{
  "username": "alice@vincss.example.com",
  "user_id": "u-42",
  "teleportGroup": ["admins", "developers"]
}
```

If the JSON keys in your VinCSS deployment differ, edit the `json:"..."` tags on `VinCSSUserResponse` in `lib/auth/github.go`.

### Logging in

Once the connector is created and the auth process has the env vars set:

- **Web UI**: a button labeled with `spec.display` (or `vincss` if unset) appears on the login screen.
- **tsh**: `tsh login --auth=vincss --proxy=<proxy-public-addr>`.

### Operational notes

- The GitHub Enterprise OSS guard (which normally rejects non-`github.com` endpoint URLs in OSS builds) is bypassed when `sub_kind: vincss`.
- The `/orgs/<org>/sso` probe used to detect GitHub-Enterprise SSO is also skipped for VinCSS — it is github.com-specific and would always fail.
- The connector emits the same audit events as the GitHub connector (`github.created`, `github.updated`, `github.deleted`, `user.login` with `method: github`).

---

## VinCSS OIDC connector (sub_kind: vincss_oidc)

VinCSS OIDC is a `kind: oidc` connector that is exempt from the Enterprise-only OIDC entitlement and is served by an in-tree OSS implementation. The flow is the standard OIDC authorization-code grant with PKCE: OIDC discovery, JWKS-based ID token signature verification, and claim-based role mapping. No environment variables are needed — every endpoint is taken from the issuer's `/.well-known/openid-configuration` document at runtime.

### Prerequisites

- The VinCSS deployment must serve a standards-compliant OIDC discovery document at `<issuer_url>/.well-known/openid-configuration` with `authorization_endpoint`, `token_endpoint`, and `jwks_uri`.
- The OIDC client must be configured to allow the authorization-code response type, PKCE (`S256`), and the redirect URL `https://<proxy-public-addr>/v1/webapi/oidc/callback`.

### Example connector

Save as `vincss-oidc-connector.yaml` and apply with `tctl create -f vincss-oidc-connector.yaml`.

```yaml
kind: oidc
sub_kind: vincss_oidc
version: v3
metadata:
  name: vincss-oidc
spec:
  # OIDC issuer URL — discovery is fetched from <issuer_url>/.well-known/openid-configuration.
  issuer_url: https://sso.vincss.example.com

  # OAuth2 client credentials issued by the VinCSS IdP.
  client_id: <vincss-oidc-client-id>
  client_secret: <vincss-oidc-client-secret>

  # Proxy URL VinCSS redirects to after the user authorizes the request.
  redirect_url:
    - https://<proxy-public-addr>/v1/webapi/oidc/callback

  # Optional: scopes requested in addition to openid. openid is added
  # automatically if missing.
  scope: [email, profile, groups]

  # Optional: button label shown on the login screen.
  display: VinCSS OIDC

  # Map ID token claims to Teleport roles. The connector evaluates each
  # mapping in order: for every claim whose value matches (literal string
  # equality, or membership in a JSON array), the listed roles are granted.
  claims_to_roles:
    - claim: groups
      value: admins
      roles: [access, editor, auditor]
    - claim: groups
      value: developers
      roles: [access]
    - claim: role
      value: owner
      roles: [editor]
```

### Expected ID token claims

The OSS implementation extracts the username from the first non-empty value among `preferred_username`, `email`, `username`, and falls back to the `sub` claim. Every other claim is flattened into Teleport traits and is available to login rules and role templates.

Minimum ID token payload that passes a `claims_to_roles: [{claim: groups, value: admins, roles: [access]}]` mapping:

```json
{
  "iss": "https://sso.vincss.example.com",
  "aud": "<vincss-oidc-client-id>",
  "sub": "user-uuid",
  "preferred_username": "alice@vincss.example.com",
  "email": "alice@vincss.example.com",
  "groups": ["admins"],
  "iat": 1747136400,
  "exp": 1747140000
}
```

Both scalar claims (`"role": "owner"`) and array claims (`"groups": ["admins", "devs"]`) are supported — the connector tests the value against each element of an array claim.

### Logging in

- **Web UI**: a button labeled with `spec.display` appears on the login screen.
- **tsh**: `tsh login --auth=vincss-oidc --proxy=<proxy-public-addr>`.

### Operational notes

- The OSS OIDC entitlement gate is bypassed only for connectors whose `sub_kind == vincss_oidc`. Standard `kind: oidc` connectors without that sub-kind still require Teleport Enterprise.
- ID token signatures are verified against the JWKS published by the issuer; the connector refuses tokens whose signing key is not present in JWKS.
- PKCE (`S256`) is always used. The verifier is stored in the auth request record (`PkceVerifier` field) and consumed on callback.
- If `claims_to_roles` produces zero matching roles for a user the login is rejected with `AccessDenied` and an `user.login` failure audit event.
- Audit events use the standard OIDC codes (`T8100I` create / `T8102I` update / `T8101I` delete) and `user.login` with `method: oidc`.

### Troubleshooting

| Symptom                                                      | Likely cause                                                                                    |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `OIDC is only available in Teleport Enterprise`              | `sub_kind` not set to `vincss_oidc` — the entitlement bypass requires the exact sub-kind value. |
| `Failed to verify VinCSS OIDC ID token`                      | JWKS does not contain the key that signed the ID token (key rotation lag, wrong `kid`).         |
| `VinCSS OIDC user "..." has no roles matched by claims_to_roles` | The claim/value pair the user actually has does not appear in any `claims_to_roles` entry.  |
| `VinCSS OIDC discovery failed`                                | `issuer_url` unreachable, returns non-200, or the discovery JSON lacks `jwks_uri`.              |
