---
kind: implementation
serves: [P-01, P-04, P-05]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-embedded-liveview-workspace, defdo-tenant-edge-contract, defdo-woodpecker-pipeline]
repo: defdo-dev/defdo_cms, defdo-dev/defdo_theme_hub
---

# Slice 11 — Hosts: defdo_cms and defdo_theme_hub on the contract

Two PRs, one per repo, shaped like 09/10. Work only inside the named repository per PR.

## Ecosystem

- uses: defdo_auth_client@0.15 `Site`, `Identity`, `Plug.Identity`, `LiveHook`, library
  PKCE plug; defdo_dev_idp@0.1; defdo_vault `Runtime` child; defdo_tenant_plug@0.3.1
  (cms already mounts `Defdo.TenantPlug.LiveView` — `router.ex:203`; theme_hub standalone
  studio uses `{:static}`-style single tenant: `resolver: [{:static, tenant_id: …}]` is
  not a config value → read the pinned tenant from the `Site` app record in a custom
  resolver `resolve/2`).
- replaces (cms, verified checkout 2026-11-08): own PKCE plug
  `lib/defdo_cms/auth/authorize_code_with_pkce_plug.ex` (cookie `@cookie_user_token "_defdo_auth_me"`
  `:15`, `ensure_user_token/1` `:127-133` reading session `:user_token` then the signed cookie)
  + `lib/defdo_cms/auth/strategy/auth_code_pkce.ex` + `lib/defdo_cms/auth/code_with_pkce_adapter.ex`
  → library plug with session `:user_token` (`SessionStores.Default`); the cookie is dropped
  (a one-release transition: the library plug's `drop_legacy_identity_cookie/0` already
  removes legacy cookies — verify it covers this name, else add the name in the CLIENT as a
  contract option); callers `lib/defdo_cms_web/plug/upstream_current_user.ex`,
  `lib/defdo_cms_web/router.ex:160-163`, `lib/defdo_cms/mcp/defdo_auth_introspector.ex`
  (→ `SDK.introspect_credential/3` through `Site.introspection/1`), `lib/defdo/oauth/vault_secret.ex`
  (cms's copy of the same reader → `Site`). Adapters `oauth_client_adapter.ex`,
  `default_oauth_client_adapter.ex`, `oauth_secret_store.ex`, `oauth_config.ex`,
  `oauth_client_secret.ex` → `Site`; `current_user_adapter.ex` + `default_current_user_adapter.ex`
  (`Defdo.Cms.Auth.current_user_adapter/0`, `auth.ex:11-14`) → `Identity`;
  `Defdo.CmsWeb.Hook.User.maybe_assign_current_user/2` → `LiveHook`. The `/admin/auth-idp`
  form (`AuthSettingsLive.Form`) edits through `Site.put/2`. KEPT: `enforcer.ex` +
  `default_enforcer.ex` (`:cms_access`), `Defdo.CmsWeb.Plug.SetupGate`/install.
- replaces (theme_hub): `studio_authenticator.ex` + `plug/studio_auth.ex` (`:21,27,34`) +
  `hook/studio_auth.ex` → library PKCE plug on `/oauth2/defdo_auth` + `Plug.Identity`
  `require: true` on the studio pipeline + `LiveHook` `{:require_identity, …}`. KEPT:
  `Api.Auth.mode() == :open` (embedded/no-auth mode, a product decision).
- gap: none.

## Goal

Both hosts read the IdP through `Site` (Runtime child after Repo) and the user through
`Identity`; `mix setup && mix phx.server`, cms `/admin` or the studio root → picker →
profile → page; prod artifacts carry nothing; gates in pipelines.

## Preconditions

`defdo_auth_client` 0.15.0, `defdo_dev_idp` 0.1.0; slices 09 and 10d merged.

## Steps (per repo)

1. Deps, `:env`, `site: [vault_project: …]`, Provider entry, dev credentials keyword,
   `:defdo_dev_idp` block (ports cms 4102, theme_hub 4103; `provision: [repo: …]`),
   children `Repo → Runtime → DevIdp → Endpoint`, `setup` alias.
2. Replace per Ecosystem; `Release.migrate_site_records/0` for cms (old record → contract),
   idempotent.
3. theme_hub prod mode decision: the standalone studio is deployed as ONE instance per
   deployment → `Site` app record only (no customer records); recorded in its decision file.
4. Gate script copy + pipeline/Dockerfile lines (locate with `grep -n "mix release" Dockerfile .woodpecker/*.yml`);
   runbooks; PROCESS_MAP rows; screenshots `11-cms-admin-*.png`, `11-studio-*.png`.

## Tests

- cms: login through the library plug against the dev IdP; `Hook.User` gets `current_user`
  from `Identity`; `:cms_access` admits the staff profile; migration idempotent; the MCP
  introspector uses `Site.introspection/1` (fake consumer).
- theme_hub: studio redirects to `/oauth2/defdo_auth` without identity; mounts after a dev
  login; `Api.Auth.mode() == :open` bypass intact.

## Verification (each repo; cms lines marked C, theme_hub T)

```sh
grep -q 'defdo_dev_idp' mix.lock
grep -q '"~> 0.15"' mix.exs
grep -q 'defdo_dev_idp.seed' mix.exs
grep -q 'vault_project:' config/runtime.exs
grep -q 'Site.vault_set(' lib/*/application.ex
test -x scripts/ci/assert-no-dev-idp.sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
! MIX_ENV=prod mix deps.tree --only prod | grep -q defdo_dev_idp
```

C: `! test -f lib/defdo_cms/auth/authorize_code_with_pkce_plug.ex`, `! test -f lib/defdo_cms/auth/default_current_user_adapter.ex`,
`! test -f lib/defdo_cms/auth/oauth_secret_store.ex`, `! grep -rn "_defdo_auth_me" lib/`.
T: `! test -f lib/defdo_theme_hub_web/studio_authenticator.ex`, `grep -q "Defdo.AuthClient.Plug.Identity" lib/defdo_theme_hub_web/router.ex`.
Both: the gate line grep for the repo's release/image pipeline, written once located.

## Acceptance criteria

- [ ] Replaced files deleted; enforcer / `Api.Auth.mode` kept; decision files with reasons.
- [ ] cms migration idempotent; login tests green in both; gates in pipelines; screenshots.
