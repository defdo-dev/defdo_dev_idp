# Changelog

## 0.1.0 — unreleased

### Added

- Host-supervised `Defdo.DevIdp` server on `127.0.0.1` (no package `mod:`).
- Boot check against `Defdo.AuthClient.Site.sites/1` with three outcomes: ready,
  unseeded, refused (`Defdo.DevIdp.BootError`).
- `Defdo.DevIdp.recheck/0` and a per-request re-check while unseeded.
- Loopback-only plug: non-loopback peers get 404.
- Index page and OpenID Connect discovery document.
- The dev-IdP mark `defdo_idp_mark: "defdo-dev-idp"` (`Defdo.DevIdp.Mark`) in the
  discovery document. defdo_auth_client refuses a marked IdP outside `:dev`/`:test`.
- Authorize endpoint with a profile picker bound to the request (`picker_token`), a
  headless `profile=` path and `prompt=none` (`login_required`); legacy alias
  `/openid/authorize`.
- PKCE S256 only; single-use codes (60 s); token endpoint with body or Basic client
  authentication; RS256 id_token and JWKS.
- Every id_token carries the dev-IdP mark claim `defdo_idp_mark`.
- `POST /oauth/introspect`, `POST /api/v1/introspect` (`x-internal-token`),
  `GET /openid/userinfo`, and `POST /session/clear` ("Sign out everywhere").
- Userinfo and every active introspection answer carry `defdo_idp_mark`.
- `mix defdo_dev_idp.seed`: tenants through `Defdo.Tenant.Provision`, Site records through
  `Defdo.AuthClient.Site.put/2`; idempotent; refuses foreign records and non-dev envs.
- Dev service client (`<id>-svc`) with `grant_type=client_credentials`.
- Every seeded Site record carries `idp_mark: "defdo-dev-idp"` (vault code
  `auth.idp_mark`); a record of this dev IdP without the mark is rewritten with it.
- Release gate: `scripts/ci/assert-no-dev-idp.sh` (`release` and `deps` modes, fail-closed)
  and `Defdo.DevIdp.Gate.assert_absent!/1`.
- Integration proof: a fake host signs in through the real PKCE plug, reads the real
  `Identity`, and introspects through the real SDK.
