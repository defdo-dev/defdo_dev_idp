# Changelog

## 0.1.0 — unreleased

### Added

- Production guard: `Defdo.DevIdp` refuses to start (`BootError` `{:env_not_allowed, env}`,
  no supervisor, no site read) unless the host environment is `:dev` or `:test`. The env is
  read through `Defdo.AuthClient.Env.current/0` (`config :defdo_auth_client, :env`, default
  `:prod`), so an undeclared env is refused. Requires defdo_auth_client `~> 0.15.1`.

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
