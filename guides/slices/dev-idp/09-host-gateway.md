---
kind: implementation
serves: [P-01, P-02, P-03, P-04, P-05, P-06, P-07]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-tenant-edge-contract, defdo-tenant-platform-kit, defdo-safe-test-data, defdo-woodpecker-pipeline]
repo: defdo-dev/defdo_gateway
---

# Slice 09 — Host: defdo_gateway on the vault-only contract + local login

Work only inside `defdo_gateway`. Read this set's `00-conventions.md` (copy under
`guides/slices/dev-idp/` with a provenance line) and the gateway's own conventions.

## Ecosystem

- uses: defdo_auth_client@0.15 — `Site` (app record via `Defdo.Vault.Runtime`), `Identity`;
  PKCE plug resolves through `Site` (slice 02).
- uses: defdo_vault@0.21.2 — `Defdo.Vault.Runtime` child with `Site.vault_set("gateway", env)`
  after `Repo`; the gateway already configures a dev keyring (`config/dev.exs:3-13`) and
  calls `Consumer.resolve_secret/3` + `upsert_secret/2`.
- uses: defdo_dev_idp@0.1 — `Defdo.DevIdp` child (dev), `mix defdo_dev_idp.seed`, gate script.
- uses: defdo_tenant_provision@0.3.0 — the adapters the gateway already configures for its
  first run (`grep -rn "defdo_tenant_provision" config lib | head`); the seed reuses them.
- uses: defdo_tenant_plug@0.3.1 — already in `mix.exs:73`; the admin pipelines stay as they are.
- uses: defdo_tenant@0.24.1 — `Defdo.Tenant.Context.with_context/2` (inside `Site`, and in
  `Release.migrate_site_record/0`).
- uses: gateway `Defdo.Gateway.Membership.tenants_for/1` + `grant/3` (`membership.ex:55-90`).
- replaces: `Setup.AdminConfig` four-code read (`setup/admin_config.ex:135-139`) and its
  `InstanceTenant`-based operator tenant (`admin_config.ex` moduledoc "platform tenant is
  discovered from the catalog's audited platform-provider read", `setup/instance_tenant.ex:78`
  `id/0`) → `Site.resolve(%{})` and the pinned `client.tenant`;
  `ProvisionWebCredentialStore.persist_admin_access/3` four-code write
  (`provision_web_credential_store.ex:18-37`) → `Site.put(%{vault_tenant_id: tenant.tenant_id}, …)`;
  `Plugs.AdminScope.operator?/1` tenant source → `client.tenant`. KEPT: `AdminScope.admit/1`
  rules (operator = `ai:admin` AND tenant match; customer = membership), the `:introspector`
  test seam, `AdminAuth`, the wizard UI and `ProvisionWebAdapter` (its `admin_access_context/1`
  env reads are the provision_web clash recorded out of scope). Decision file
  `.ai/decisions/2026-11-dev-idp-site.md` lists replaced vs kept and the owner's words:
  the `InstanceTenant` platform-tenant path "está mal implementado".
- gap: none.

## Goal

The gateway admin login reads ONE vault record through `Site`; `AdminScope` admits an
operator whose introspected tenant equals the record's pinned `tenant`; existing
deployments migrate their four `admin-*` codes once. Fresh clone → `mix setup` →
`mix phx.server` → `/admin` → picker → Operator → admin shell; Customer · Acme → portal.
Prod release carries no dev IdP; both pipelines prove it.

## Preconditions

`defdo_auth_client` 0.15.0 and `defdo_dev_idp` 0.1.0 published. Lock sha to the owner.

## Targets

- `mix.exs` (`defdo_auth_client ~> 0.15`, `defdo_dev_idp`, `setup` alias `mix.exs:104`).
- `config/config.exs`: `config :defdo_auth_client, :env, config_env()`;
  `config/runtime.exs`: `config :defdo_auth_client, Defdo.AuthClient, site: [vault_project: "gateway"]`
  and the release `config_providers` entry `{Defdo.Vault.Provider, Defdo.AuthClient.Site.vault_set("gateway", :prod)}`
  (re-locate `releases:` in `mix.exs`); `config/dev.exs`: `config :defdo_vault, :credentials, transport: :local, tenant_id: <dev vault tenant>`
  — the dev vault tenant is the one `mix ecto.setup`'s `tenant_seed.exs` creates (code
  `"default"`): since its id is generated, the seed script is changed to create it with a
  fixed id `"00000000-0000-4000-8000-00000000000a"` through the configured provision
  adapter (Step 3), and that literal is the credentials `tenant_id`. Plus the
  `:defdo_dev_idp` block (`00-conventions.md`, `host: :defdo_gateway`, port 4100,
  `provision: [repo: Defdo.Gateway.Repo]`). Remove any `Defdo.AuthClient` `client:` block.
- `lib/defdo_gateway/application.ex`: children order `Repo → {Defdo.Vault.Runtime, Site.vault_set("gateway", env)} → Defdo.DevIdp → Endpoint`
  (`Defdo.DevIdp` as a bare atom; `enabled:` config decides; `env` from `Defdo.AuthClient.Env.current/0`).
- `lib/defdo_gateway/setup/admin_config.ex`: `fetch/0` → `Site.resolve(%{})` mapped to the
  same `{:ok, %{site, client_id, client_secret, admin_tenant_id}} | {:error, :not_configured}`
  with `admin_tenant_id = client.tenant`; `admin_tenant_id/0` likewise; `fetch_for_tenant/1`
  deleted with its callers updated (grep). `InstanceTenant` is no longer referenced from
  admission (`! grep -n "InstanceTenant" lib/defdo_gateway/setup/admin_config.ex lib/defdo_gateway_web/plugs/admin_scope.ex`).
- `lib/defdo_gateway/provision_web_credential_store.ex`: `persist_admin_access/3` →
  `Site.put(%{vault_tenant_id: tenant.tenant_id}, content)` with the contract codes (pinned
  `tenant` = payload `tenant_id`, `connection` = payload `connection` or `""`).
- `lib/defdo_gateway_web/plugs/admin_scope.ex`: only the tenant source changes
  (`AdminConfig.admin_tenant_id/0` keeps its name); session key parity test (Tests).
- `lib/defdo_gateway/release.ex` (re-locate): `migrate_site_record/0` — read the four
  legacy codes under the platform tenant once, write the app record through `Site.put/2`
  with `tenant` = legacy `admin-tenant-id`, `connection` `""`, idempotent, module-only
  logs; runbook says to run it once after deploy; the legacy codes are deleted in the
  NEXT release.
- `priv/repo/seeds/tenant_seed.exs`: fixed id through the provision adapter (Step 3).
- `lib/dev/` nothing: no host seeder exists in this design. Membership for the customer
  profile: `priv/repo/seeds/dev_idp_membership.exs` run by the `setup` alias AFTER
  `defdo_dev_idp.seed` (`Membership.grant("00000000-0000-4000-8000-000000000002", "dev-customer-acme", "member")`
  if absent) — a host-domain row, outside the package by design.
- `scripts/ci/assert-no-dev-idp.sh` (copy, provenance), `.woodpecker/release.yml` (`:28`),
  `Dockerfile` (`:58`), `guides/runbooks/dev-login.md`, `guides/PROCESS_MAP.md`, decision file.

## Step 1 — Deps, config, children

As in Targets. `setup: ["deps.get", "ecto.setup", "defdo_dev_idp.seed", "run priv/repo/seeds/dev_idp_membership.exs", "assets.setup", "assets.build"]`.

## Step 2 — `AdminConfig` and the credential store on `Site`

```elixir
def fetch do
  case Site.resolve(%{}) do
    {:ok, %Site.Client{} = c} -> {:ok, %{site: c.site, client_id: c.client_id, client_secret: c.client_secret, admin_tenant_id: c.tenant}}
    {:error, _} -> {:error, :not_configured}
  end
end
def admin_tenant_id, do: with({:ok, %{admin_tenant_id: t}} <- fetch(), do: {:ok, t})
```

The operator tenant is the PINNED estate tenant from the record — never a DB selector.

## Step 3 — Deterministic dev tenants through provision

`tenant_seed.exs` and the dev IdP seed both call the gateway's configured provision
adapters. Check whether the profile adapter honours `"tenant_id"` in params
(`grep -rn "tenant_id" lib/defdo_gateway/provision/*.ex`); if it does not, add it there
(host-owned adapter) AND file the defdo_tenant_provision follow-up named in slice 07.

## Step 4 — Gates, runbook, look

- `.woodpecker/release.yml` `release-validate` after `mix release --overwrite`:
  `- sh scripts/ci/assert-no-dev-idp.sh deps` and `- sh scripts/ci/assert-no-dev-idp.sh release _build/prod/rel/defdo_gateway`.
- `Dockerfile:58`: `… && mix release --overwrite && sh scripts/ci/assert-no-dev-idp.sh deps && sh scripts/ci/assert-no-dev-idp.sh release _build/prod/rel/defdo_gateway`.
- Runbook: four commands, picker, "Sign out everywhere", headless `&profile=operator`,
  `Release.migrate_site_record/0` for existing deployments.
- Look (session): screenshots `09-admin-operator-{light,dark,390}.png`, `09-portal-customer.png`.

## Process map

| Activity | Where it hangs | Starts after | Stopping it stops | Owns | Alive? |
|---|---|---|---|---|---|
| `Defdo.Vault.Runtime` (Site set) | gateway children, after `Repo` | Repo | rotation refresh (config keeps last values) | the app record in app env | `Process.whereis(Defdo.Vault.Runtime)` |
| `Defdo.DevIdp` (dev) | gateway children, after the Runtime | Runtime | local logins | see package | `Process.whereis(Defdo.DevIdp)` |

## Tests

- `admin_config_test.exs`: app record in env (Runtime output shape) → `fetch/0` ok with
  `admin_tenant_id == tenant`; missing → `:not_configured` (guard: the match).
- `provision_web_credential_store_test.exs`: writes the contract codes through `Site.put/2`
  (fake consumer sees `auth.*`, no `admin-oauth-*`).
- `release_migrate_site_record_test.exs`: four legacy codes → one record; second run unchanged.
- `admin_scope_dev_idp_test.exs`: `start_supervised!({Defdo.DevIdp, enabled: true, port: 0, …})`,
  app record in env pointing at it, token via `profile=operator` + exchange, session key
  the PKCE plug writes, REAL `Defdo.AuthClient.SDK` introspector →
  `%{"role" => "operator", "tenant_id" => "00000000-0000-4000-8000-000000000001"}`.
- Session-key parity: the plug's stored key == the key `AdminScope` reads.
- Membership seed idempotent (second run no insert).

## Verification

```sh
grep -q 'defdo_dev_idp' mix.lock
grep -q 'only: \[:dev, :test\]' mix.exs
grep -q 'defdo_dev_idp.seed' mix.exs
grep -q 'vault_project: "gateway"' config/runtime.exs
grep -q 'Site.vault_set(' lib/defdo_gateway/application.ex
! grep -rn 'InstanceTenant' lib/defdo_gateway/setup/admin_config.ex lib/defdo_gateway_web/plugs/admin_scope.ex
! grep -rn 'admin-oauth-site' lib/ --exclude=release.ex
test -x scripts/ci/assert-no-dev-idp.sh
grep -q 'assert-no-dev-idp.sh deps' .woodpecker/release.yml
grep -q 'assert-no-dev-idp.sh release' .woodpecker/release.yml
grep -q 'assert-no-dev-idp.sh release' Dockerfile
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test --include slow
! MIX_ENV=prod mix deps.tree --only prod | grep -q defdo_dev_idp
```

(Match `mix test --include slow` to `grep -n "mix test" .woodpecker/release.yml`.)

## Acceptance criteria

- [ ] `AdminScope.admit/1` rules unchanged (diff touches only the tenant source line and nothing in `admit/1`).
- [ ] No `InstanceTenant` in admission; no `admin-oauth-*` outside `release.ex`.
- [ ] Runtime child before the dev IdP; decision file; runbook; screenshots.
- [ ] Both gates in release.yml and Dockerfile; lock sha approved.
