---
kind: implementation
serves: [P-01]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-sso-flow-test, defdo-exunit-quality-tests]
repo: defdo-dev/defdo_my_mvno
---

# Slice 10b — my_mvno: the library PKCE plug replaces `Defdo.Plug.DefdoAuthPKCE`

Work only inside `defdo_my_mvno`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_auth_client@0.15 `Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE` (options
  verified 0.14.0 moduledoc: `:resolve_client` (default = `Site`, slice 02),
  `:session_store`, `:token_auth_method` (from the record), `:authorize_params`
  `fn params, conn -> params end`, `:enrich_user` `fn user, context -> user end`,
  `:sync_oauth_app`, `state_store: :session | :cache`), `Site.Client` fields
  `registration_type`, `connection_type`, `authorize_url`, `token_auth_method`.
- replaces: `Defdo.Plug.DefdoAuthPKCE` (`lib/defdo/plug/defdo_auth_pkce.ex`, verified
  `origin/main` 2026-11-08) and its wiring in `lib/defdo/router.ex`; the host-specific
  authorize params it adds (`registration_type`, `connection_type`, `actor_type`) and
  its fallback-role enrichment become `:authorize_params` / `:enrich_user` hooks fed
  from the `Site` record (contract fields) — read the module first and list every
  behaviour it has in the decision file; anything the library plug cannot express is a
  **contract gap → slice in defdo_auth_client**, never a my_mvno branch.
- gap: to be confirmed by reading the plug: if it carries behaviour the two hooks cannot
  express (e.g. a per-request `connection_type` chosen by the visitor), the slice stops
  and files the contract slice first.

## Goal

Every my_mvno login route runs the library plug; `registration_type`/`connection_type`
come from the tenant's `Site` record (`:authorize_params`), `actor_type` and the fallback
role are set in `:enrich_user` from the record + userinfo; `Defdo.Plug.DefdoAuthPKCE` is
deleted. Login against the dev IdP works for both profiles.

## Preconditions

10a merged.

## Targets

- `lib/defdo/router.ex` (the pipelines/macros that mount the old plug), `lib/defdo/plug/defdo_auth_pkce.ex`
  (delete), `lib/my_mvno_web/plug/cms_fetch_current_user.ex` (references it; re-point to
  `Identity` in 10d — here only compile), `lib/my_mvno/auth/oauth_login_config.ex` (the
  hooks' source of scopes/types; reads the record after 10c, old config until then).

## Step 1 — Mount the library plug

```elixir
plug Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE,
  state_store: :session,
  authorize_params: &Defdo.MyMvno.Auth.LoginHooks.authorize_params/2,   # adds registration_type/connection_type from Site.resolve(%{conn: conn})
  enrich_user: &Defdo.MyMvno.Auth.LoginHooks.enrich_user/2             # actor_type + fallback role from record.raw / userinfo
```

`LoginHooks` is 2 pure functions over `Site.Client.t()` and the userinfo map — no vault
reads of its own.

## Step 2 — Delete the old plug; decision file lists each old behaviour → new home.

## Tests

- Login test through the router against `start_supervised!({Defdo.DevIdp, …})` (app record
  in env): redirect carries `registration_type`/`connection_type` from the record (guard:
  `authorize_params`); callback yields a profile with `actor_type` set (guard: `enrich_user`).
- `! test -f lib/defdo/plug/defdo_auth_pkce.ex`.

## Verification

```sh
! test -f lib/defdo/plug/defdo_auth_pkce.ex
grep -q 'Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE' lib/defdo/router.ex
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

## Acceptance criteria

- [ ] Old plug deleted; both hooks tested; decision file maps every old behaviour.
- [ ] No my_mvno-only auth behaviour outside the two hooks (reviewer checks the diff).
