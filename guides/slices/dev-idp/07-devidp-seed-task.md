---
kind: implementation
serves: [P-07]
skills: [defdo-platform, defdo-safe-test-data, defdo-exunit-quality-tests, defdo-tenant-edge-contract, defdo-tenant-platform-kit]
repo: defdo-dev/defdo_dev_idp
---

# Slice 07 — `mix defdo_dev_idp.seed`: Site records through `Site.put/2`, tenants through provision

Work only inside `defdo_dev_idp`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_auth_client@0.15 — `Site.put/2`, `Site.resolve/1`, `Site.bootstrap?` is NOT
  used (no first-run here), `Defdo.AuthClient.Env.current/0`, `Defdo.Vault.Runtime.refresh/0`
  via `Site.put/2`.
- uses: defdo_vault@0.21.2 — `Defdo.Vault.Credentials` dev/test keyword (`transport: :local`,
  `tenant_id`) is the vault tenant the APP record is written under.
- uses: defdo_tenant_provision@0.3.0 — `Defdo.Tenant.Provision.run(params, source: :dev_idp_seed,
  idempotency_key: tenant_id, steps: Defdo.Tenant.Provision.Steps.from_adapters(), repo: repo)`
  (`provision.ex:112`, `steps.ex:54`; the host configures `config :defdo_tenant_provision,
  store:, repo:, adapters:` for its own install — README "Usage"). Idempotency: the same
  `(source, idempotency_key)` never provisions twice (README "Idempotency").
- uses: defdo_tenant@0.24.1 — `Defdo.Tenant.Context.with_context/2` around every per-tenant
  write (inside `Site.put/2`; and around the customer-record write loop here).
- gap (defdo_tenant_provision): whether the configured profile adapter honours an explicit
  `tenant_id` param for a DETERMINISTIC dev tenant id is adapter-defined
  (`Provision.tenant_id/2` reads `:tenant`/`:profile` results, `provision.ex:151`). The
  implementer checks the host's profile adapter in slice 09; if it generates ids, file
  `review-followup` "explicit tenant_id for deterministic dev tenants" in
  defdo_tenant_provision and, until then, the seed READS the generated id back and the
  dev IdP profiles use `tenant: <slug>` with `tenant_id` resolved at boot from the tenant
  registry by slug (`Config` gains `tenant_id: {:by_code, "acme"}`; `Profile.new!/1`
  resolves it through `Defdo.Tenant.get_profile_by/1` at the host's named registry edge).
  Record which path each host took.
- gap: none else.

## Goal

`mix defdo_dev_idp.seed` on a fresh host database: (1) provisions one tenant per distinct
profile tenant through `Provision.run/2` (names `Defdo Red (sample)`, `Acme (sample)`);
(2) writes the APP `Site` record (dev IdP site, pinned `tenant` = first profile's
`tenant_id`, `connection` `"dev-connection"`, dev login client, dev service client,
scopes = union, `app_record_extra`) under the dev vault tenant; (3) writes one CUSTOMER
`Site` record per other profile tenant; (4) `Defdo.DevIdp.recheck/0` → `ready`; prints
one line per step. Second run changes nothing. Refuses unless `Env.current()` is
`:dev`/`:test`.

## Preconditions

Slices 04–06 merged.

## Targets

- `lib/defdo/dev_idp/seed_runner.ex`, `lib/mix/tasks/defdo_dev_idp.seed.ex` (new);
  `lib/defdo/dev_idp/config.ex`: `app_record_extra` (map, string keys, optional),
  `provision: [repo: module()]` (required by the task; the host's Repo for `Provision.run/2`).
- Slice 05's token handler: add `grant_type=client_credentials` for the dev service
  client (`config.client.id <> "-svc"` / `config.client.secret <> "-svc"`), scope =
  `service_scopes` from the app record (`~w(api:admin)` default).

## Step 1 — SeedRunner, in this exact order

1. **env** — `ensure_env!(Env.current())` (Step 2 of the task).
2. **tenants** — for each distinct `profile.tenant_id` in profile order:
   `Provision.run(%{"name" => label_for(tenant), "domain" => "localhost", "tenant_id" => tenant_id},
   source: :dev_idp_seed, idempotency_key: tenant_id, steps: Steps.from_adapters(), repo: config.provision.repo)`
   → `{:ok, %Result{already_processed?: false}}` → `tenant <id>: provisioned`;
   `already_processed?: true` → `unchanged`; `{:error, reason, _}` / `{:error, reason}` → stop.
3. **app record** — `vault_tenant = Defdo.Vault.Credentials.read!().tenant_id` (dev/test
   keyword); desired = `%{"site" => base, "tenant" => first.tenant_id, "connection" => "dev-connection",
   "client_id" => id, "client_secret" => secret, "redirect_uri" => config.redirect_uri,
   "scopes" => union_scopes, "service_client_id" => id <> "-svc", "service_client_secret" => secret <> "-svc",
   "service_scopes" => "api:admin", optional codes => ""} |> Map.merge(config.app_record_extra)`;
   `Site.resolve(%{})` equal on `site`/`client_id`/`tenant` → `unchanged`; `{:error, _}` →
   `Site.put(%{vault_tenant_id: vault_tenant}, desired)` → `written`; present but
   `site` elsewhere → `{:error, {:foreign_app_record, site}}` (never overwrite a credential
   this task did not write).
4. **customer records** — for each profile tenant ≠ `first.tenant_id`, inside
   `Context.with_context(tenant_id, fn -> … end)`: `Site.resolve(%{tenant_id: tenant_id})`
   equal → `unchanged`; missing → `Site.put(%{tenant_id: tenant_id}, content)` (dev client,
   dev base, that tenant's profile scopes, `app_record_extra`); elsewhere →
   `{:error, {:foreign_site_record, tenant_id, site}}`.
5. **recheck** — `Defdo.DevIdp.recheck/0` when running; print `dev idp: ready|unseeded`.

## Step 2 — The task

```elixir
defmodule Mix.Tasks.DefdoDevIdp.Seed do
  use Mix.Task
  @shortdoc "Seeds dev tenants and the Site vault records for every dev IdP profile (dev/test only)"
  @requirements ["app.config"]
  @impl true
  def run(_args) do
    ensure_env!(Defdo.AuthClient.Env.current())   # host config, never Mix.env(): a dependency's Mix.env() is :prod in host builds
    Mix.Task.run("app.start")                      # the dev IdP comes up :unseeded on a fresh DB (slice 04) — expected here
    case Defdo.DevIdp.SeedRunner.run(Defdo.DevIdp.Config.fetch!()) do
      {:ok, lines} -> Enum.each(lines, &Mix.shell().info/1)
      {:error, reason} -> Mix.raise(Defdo.DevIdp.SeedRunner.format_error(reason))
    end
  end
  @doc false
  def ensure_env!(env) when env in [:dev, :test], do: :ok
  def ensure_env!(env), do: Mix.raise("defdo_dev_idp.seed runs only when config :defdo_auth_client, :env is :dev or :test (got #{inspect(env)})")
end
```

## Step 3 — README "Seeding"

The alias `setup: ["deps.get", "ecto.setup", "defdo_dev_idp.seed", "assets.setup", "assets.build"]`;
the fresh-DB story (`:unseeded` → seed → `ready`); the writer rule (the seed uses the SAME
`Site.put/2` hosts use for their migrated records — no second shape); sample data
invented only (`Defdo Red`, `Acme`), never a real customer, email or phone.

## Process map

Process map: no long-lived activity added or changed.

## Tests

- `seed_runner_test.exs` with a fake `Defdo.Vault.Consumer` and a fake provision store
  (`config :defdo_tenant_provision, store: FakeStore` — the README names `store:` as
  configurable) plus a test profile adapter: order tenants → app → customers → recheck
  (recorded calls; guard: the sequence); first run provisions two tenants, writes the app
  record (17 codes under the credentials tenant, `tenant` = first profile's id) and one
  customer record; second run every line `unchanged` and no writes; foreign app record →
  error, untouched; customer writes happen inside `with_context` (the fake consumer
  asserts `Context.tenant_id/0 == tenant_id` at call time — guard: the wrapper).
- `fresh_db_test.exs`: server `:unseeded` → seed → `recheck/0` `:ready` → authorize not 503.
- `token_client_credentials_test.exs`: the `-svc` client mints a token; a login client
  with `client_credentials` → 400 `unauthorized_client`.
- `mix_task_test.exs`: `ensure_env!(:prod)` raises with `runs only when`.

## Verification

```sh
! grep -rn "Mix.env()" lib/
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix help defdo_dev_idp.seed
grep -q "Provision.run(" lib/defdo/dev_idp/seed_runner.ex
grep -q "Site.put(" lib/defdo/dev_idp/seed_runner.ex
grep -q "with_context(" lib/defdo/dev_idp/seed_runner.ex
grep -q "client_credentials" lib/defdo/dev_idp/web/token.ex
! grep -rqn "Seeder\|admin-tenant-id\|gateway\|my_mvno\|defdo_cms\|theme_hub" lib/
```

## Acceptance criteria

- [ ] Tenants only through `Provision.run/2`; records only through `Site.put/2`; no
      `Seeder` behaviour, no raw inserts (`! grep -rn "Repo.insert" lib/`).
- [ ] Order, idempotency, foreign-record refusal, context wrapper tested by name.
- [ ] Fresh-DB test green; env refusal via host config.
- [ ] README "Seeding" present; deterministic-id gap recorded if hit.
