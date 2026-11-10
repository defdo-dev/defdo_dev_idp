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
