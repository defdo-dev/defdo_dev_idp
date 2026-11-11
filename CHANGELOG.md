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
