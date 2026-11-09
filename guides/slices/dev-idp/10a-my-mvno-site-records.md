---
kind: implementation
serves: [P-05, P-07]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-tenant-edge-contract, defdo-tenant-platform-kit]
repo: defdo-dev/defdo_my_mvno
---

# Slice 10a — my_mvno: `Site` records, otp_app re-key, record mapping, migration

Work only inside `defdo_my_mvno`. First of four (10a → 10b → 10c → 10d). Read this set's
`00-conventions.md` and the repo's conventions.

## Ecosystem

- uses: defdo_auth_client@0.15 `Site` (app record via Runtime; customer records via Consumer).
- uses: defdo_vault@0.21.2 `Defdo.Vault.Runtime`, `Consumer`; my_mvno already uses the vault
  (`lib/my_mvno/vault_access.ex`, `lib/defdo/oauth/vault_secret.ex`).
- uses: defdo_tenant@0.24.1 `Defdo.Tenant.Context.with_context/2` in the migration task.
- replaces: `Defdo.OAuth.VaultSecret` record shape (`lib/defdo/oauth/vault_secret.ex`,
  verified `origin/main` 2026-11-08: `create_secret/2` `:37`, `fetch_client_config/2` `:79`,
  `put_service_client_config/2` `:109`, `oauth_config_for_request/2` `:155`, code
  `runtime_code/0 = "defdo_auth"` `:281`, `project_key/0` `:226-229` from
  `:auth_vault_project_key`, otp_app `current_otp_app/0` `:219`) and
  `Defdo.OAuth.VaultClientSecret` (`client_id`, `client_secret`, `site`, `redirect_uri`,
  `authorize_url`) → one `Site` customer record per tenant (code `defdo_auth_client`,
  `otp_app: :defdo_auth_client`) plus the app record. Callers move in 10c; this slice only
  adds the records and the migration, so 10b/10c can land one by one.
- gap: none.

## Goal

Every my_mvno tenant that has a `defdo_auth` vault client record also has a
`defdo_auth_client` record in the contract shape (same values; `authorize_url` kept as the
record's `authorize_url`; the service client from `put_service_client_config/2`'s record
folded into `service_client_*`; `token_auth_method` from where `VaultSecret` derives it
today — `grep -n token_auth_method lib/defdo/oauth/vault_secret.ex`); the deployment has
an app record; the Runtime child runs after `Repo`; a one-off release task migrates
existing records idempotently.

## Preconditions

`defdo_auth_client` 0.15.0, `defdo_dev_idp` 0.1.0 published; slice 09 merged (template).
Lock sha to the owner.

## Targets

- `mix.exs`: `defdo_auth_client ~> 0.15` (today `~> 0.12`, `mix.exs:60`), `defdo_dev_idp`,
  `setup` alias (`mix.exs:160`).
- `config/config.exs` (`:env`), `config/runtime.exs` (`site: [vault_project: <project_key/0 value>]`,
  Provider entry), `config/dev.exs` (`config :defdo_vault, :credentials` local + fixed
  dev vault tenant id as in slice 09 Step 3; `:defdo_dev_idp` block `host: :my_mvno`, port
  4101, `provision: [repo: Defdo.MyMvno.Repo]`, profiles `Staff · Defdo Red` role `admin`,
  `Customer · Acme` role `ciam`, both `tenant_id` the fixed dev tenant id, scopes
  `openid profile metadata` / `openid profile` — today's defaults, `config/dev.exs:106-107`,
  the env knob there is removed in 10c).
- `lib/my_mvno/application.ex`: `Repo → {Defdo.Vault.Runtime, Site.vault_set(project, env)} → Defdo.DevIdp → Endpoint`.
- `lib/my_mvno/release.ex` (re-locate): `migrate_site_records/0`.
- `priv/repo/seeds/tenant.exs`: fixed id through the configured provision adapter.
- `scripts/ci/assert-no-dev-idp.sh`, `Dockerfile:58`, `.woodpecker/ci.yml` (deps gate),
  `guides/PROCESS_MAP.md`, `.ai/decisions/2026-11-dev-idp-site.md` (started here, completed in 10d).

## Step 1 — Deps, config, children (as 09 Step 1, values above)

## Step 2 — Migration task

`migrate_site_records/0`: for every tenant in the registry (the app's named cross-tenant
edge — `grep -rn "skip_tenant_id" lib | head` to find it; add this module to the allowlist
test), inside `with_context(tenant_id, …)`: read the `defdo_auth` record via the OLD
`VaultSecret.fetch_client_config/1` (still present until 10c), read the service record via
`VaultSecret` as well, and `Site.put(%{tenant_id: tenant_id}, content)` when the new record
is missing; equal → skip; present-but-different → log module-only and skip (never
overwrite). Mapping table (verified fields):

| old (`VaultClientSecret`) | new content key |
|---|---|
| `site` | `"site"` |
| `client_id` / `client_secret` | `"client_id"` / `"client_secret"` |
| `redirect_uri` | `"redirect_uri"` |
| `authorize_url` | `"authorize_url"` (legacy `/openid/authorize` stays valid: defdo_auth redirects) |
| service record `client_id`/`client_secret`/scopes | `"service_client_id"`/`"service_client_secret"`/`"service_scopes"` |
| (none) | `"tenant"`, `"connection"`: the IdP tenant/connection of that customer — read from where `OAuthLoginConfig`/`Connections` hold them (`lib/my_mvno/auth/oauth_login_config.ex`, `lib/my_mvno/connections.ex`); if absent, `""` and the record is flagged in the task's summary |
| `token_auth_method` (derived) | `"token_auth_method"` |

The APP record for the deployment: `Site.put(%{vault_tenant_id: instance_tenant}, …)` from
the instance's `defdo_auth` record (`lib/my_mvno/instance_tenant.ex` names it today;
after 10c that module is reduced to the Repo lookup the registry edge needs).

## Step 3 — Gates (Dockerfile build stage `deps` + `release`; CI `deps`), PROCESS_MAP rows

## Process map

Rows for `Defdo.Vault.Runtime` and `Defdo.DevIdp` as in slice 09.

## Tests

- `release_migrate_site_records_test.exs` (fake consumer with two tenants' old records):
  new records written with the mapping; second run no writes; a differing new record is
  not overwritten (guard: the equality branch); the migration runs inside `with_context`
  (fake asserts `Context.tenant_id/0`).
- `application_children_test.exs`: child order Repo < Runtime < DevIdp (inspect
  `Supervisor.which_children/1` order in test with `enabled: false` → DevIdp `:ignore`d but
  listed).

## Verification

```sh
grep -q 'defdo_dev_idp' mix.lock
grep -q '"~> 0.15"' mix.exs
grep -q 'defdo_dev_idp.seed' mix.exs
grep -q 'vault_project:' config/runtime.exs
grep -q 'Site.vault_set(' lib/my_mvno/application.ex
test -x scripts/ci/assert-no-dev-idp.sh
grep -q 'assert-no-dev-idp.sh deps' Dockerfile
grep -q 'assert-no-dev-idp.sh release' Dockerfile
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
! MIX_ENV=prod mix deps.tree --only prod | grep -q defdo_dev_idp
```

## Acceptance criteria

- [ ] Records exist alongside the old ones (no caller moved yet); migration idempotent and
      context-wrapped (tests); mapping table applied.
- [ ] Children order tested; gates in Dockerfile/CI; lock sha approved.
