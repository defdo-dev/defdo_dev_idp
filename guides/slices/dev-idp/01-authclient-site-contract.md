---
kind: implementation
serves: [P-05]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-architecture-boundary-guardian, defdo-tenant-edge-contract, defdo-exunit-quality-tests, defdo-property-tests]
repo: defdo-dev/defdo_auth_client
---

# Slice 01 — `Defdo.AuthClient.Site`: vault is the one source

Work only inside `defdo_auth_client`. Read `00-conventions.md`. Adds the contract; changes
no caller (slice 02 does).

## Ecosystem

- uses: defdo_vault@0.21.2 — `Defdo.Vault.Provider` / `Defdo.Vault.Runtime` (`values:`
  declaration, `provider.ex` moduledoc + `runtime.ex:81-96`), `Defdo.Vault.Consumer.resolve_secret/3`
  + `upsert_secret/2` (`consumer.ex:82-100`), `Defdo.Vault.Credentials` (dev/test keyword,
  `transport: :local`, `tenant_id`). `optional: true` at compile; required at runtime by
  every host (there is no other mode).
- uses: defdo_tenant@0.24.1 — `Defdo.Tenant.Context.with_context/2` (`context.ex:110`),
  `Context.tenant_id/0` (`:98`), `Context.get/0` (`:74`): the protector of every per-tenant
  read and write in this module; tenant ids are never threaded past the edge. `optional: true`.
- gap (defdo_vault): no in-process, context-free single-record read outside the
  Provider/Runtime set, and no "list records of a project across tenants" → both filed as
  `review-followup` issues in defdo_vault, linked from the PR. Neither blocks: the set
  declaration IS the context-free read, and `sites/1` takes explicit tenant ids.
- gap: none else.

## Goal

Every host reads where its IdP is, which login and service clients it holds, and which
estate tenant/connection it is pinned to, from ONE place — vault — through
`Defdo.AuthClient.Site`; config files carry only the vault project. Customer-tenant
records (multi-tenant hosts) are the same record shape under a tenant context.

## Preconditions

None.

## Targets

- New: `lib/defdo/auth_client/env.ex`, `lib/defdo/auth_client/site.ex`,
  `lib/defdo/auth_client/site/client.ex`, `lib/defdo/auth_client/site/vault.ex` (wrapped in
  `if Code.ensure_loaded?(Defdo.Vault.Consumer)`), `lib/defdo/auth_client/site/codes.ex`.
- `lib/defdo/auth_client/config.ex` unchanged (`from_env/2`).
- `mix.exs`: `{:defdo_vault, "~> 0.21", organization: :defdo, optional: true}`,
  `{:defdo_tenant, "~> 0.24", organization: :defdo, optional: true}`; fetch + commit the lock.
- `guides/site.md` (new), `.ai/capabilities.md`.

## Step 1 — Runtime env

```elixir
defmodule Defdo.AuthClient.Env do
  @spec current() :: :dev | :test | :prod
  def current, do: Application.get_env(:defdo_auth_client, :env, :prod)   # hosts: config :defdo_auth_client, :env, config_env()
end
```

## Step 2 — Codes and the set declaration

```elixir
defmodule Defdo.AuthClient.Site.Codes do
  @app_prefix "auth."
  @keys ~w(site tenant connection client_id client_secret redirect_uri scopes registration_type connection_type
           authorize_url token_auth_method service_client_id service_client_secret service_scopes)a
  @required ~w(site tenant connection client_id redirect_uri)a
  def keys, do: @keys
  def required, do: @required
  @doc "The Provider/Runtime `values:` list for the app record: every key under [:defdo_auth_client, Defdo.AuthClient, :site, key], plus the introspection token."
  @spec vault_values() :: [{[atom()], String.t()}]
  def vault_values do
    Enum.map(@keys, &{[:defdo_auth_client, Defdo.AuthClient, :site, &1], @app_prefix <> Atom.to_string(&1)}) ++
      [{[:defdo_auth_client, Defdo.AuthClient, :introspection, :internal_api_token], @app_prefix <> "internal_api_token"}]
  end
end

# Defdo.AuthClient.Site
@spec vault_set(String.t(), :dev | :stage | :prod | :test) :: keyword()
def vault_set(project, env), do: [project: project, env: env, values: Codes.vault_values()]
```

`Codes.required/0` is the contract's required set: a Provider boot that lacks one stops
naming the code (provider semantics); `Site.resolve(%{})` after a partial Runtime write
returns `{:error, {:missing, [codes]}}`. Optional codes may be absent from the vault; a
host declares only the codes it has? NO — the set is fixed so every host record looks the
same: hosts write the optional codes with an empty string when unused (`put/2` does it).

## Step 3 — The struct

```elixir
defmodule Defdo.AuthClient.Site.Client do
  @enforce_keys [:site, :client_id, :tenant]
  defstruct [:site, :tenant, :connection, :client_id, :client_secret, :redirect_uri, :authorize_url,
             :registration_type, :connection_type, :token_auth_method, :record_tenant_id,
             scopes: [], service_client: nil, raw: %{}]
  @type service_client :: %{client_id: String.t(), client_secret: String.t(), scopes: [String.t()]} | nil
  @spec to_oauth_opts(t()) :: keyword()            # keys CodeWithPKCE.new_client/1 accepts (verified 0.14.0): strategy, client_id, client_secret, site, redirect_uri, token_auth_method, authorize_url
  @spec to_service_oauth_opts(t()) :: {:ok, keyword()} | {:error, :no_service_client}   # Adapter.ClientCredentials.new_client/1
  @derive {Inspect, except: [:client_secret, :service_client]}
end
```

`tenant`/`connection` = the pinned estate IdP tenant and connection (owner rule
2026-09-22). `record_tenant_id` = the vault tenant the record lives under (nil for the
app record read through Runtime). `raw` = unmodelled content keys (string keys).

## Step 4 — Facade

```elixir
defmodule Defdo.AuthClient.Site do
  @type ctx :: %{optional(:conn) => Plug.Conn.t(), optional(:tenant_id) => String.t()}
  @spec resolve(ctx()) :: {:ok, Client.t()} | {:error, :not_configured | {:missing, [String.t()]} | :no_tenant | term()}
  def resolve(ctx \\ %{})
  def resolve!(ctx \\ %{})
  @spec sites([String.t()]) :: [String.t()]          # app site ++ sites of the given customer tenant ids, uniq
  def sites(tenant_ids \\ [])
  @spec put(ctx(), map()) :: {:ok, Client.t()} | {:error, term()}
  def put(ctx, attrs)
  @spec introspection(ctx()) :: {:ok, %{site: String.t(), internal_api_token: String.t()}} | {:error, term()}
  def introspection(ctx \\ %{})
end
```

- `resolve(%{tenant_id: id})` → `Vault.customer_record(id)`; `resolve(%{conn: conn})` →
  if `Defdo.Tenant.Context` has a current tenant → customer record for it, else app
  record; `resolve(%{})` → app record. **No config-file values are ever read as a site**:
  `Config.from_env([:site])` is the Runtime's OUTPUT; `Site` validates that
  `Config.from_env([:site, :vault_project])` names a project and that the values present
  came with it (the Runtime writes a marker code `auth.site` — a `site:` keyword that has
  `:site` but no `:vault_project` raises `Site.NotFromVault` naming the fix). This is what
  makes "config may only name codes" enforceable.
- `impl` is always `Site.Vault`; if `Defdo.Vault.Consumer` is not loaded → `ArgumentError`
  "add {:defdo_vault, …}". No `:static`.

## Step 5 — `Site.Vault`

- `app_record/0`: `Config.from_env([:site])` → normalise (atom/string keys one level deep),
  check `Codes.required/0` present and non-empty → `Client.t()` (`scopes` split on
  spaces; `service_client` built when `service_client_id` non-empty).
- `customer_record(tenant_id)`: `Defdo.Tenant.Context.with_context(tenant_id, fn ->
  Consumer.resolve_secret(project, "defdo_auth_client", env: env) end)` with
  `project = Config.from_env([:site, :vault_project])`, `env` from `Env.current/0`
  (`:dev→:dev, :test→:test, :prod→:prod`); payload normalised (atom OR string keys —
  `Consumer.SDK` structs are atom-keyed, content maps string-keyed); content keys = the
  code names without the `auth.` prefix; unknown → `raw`; `record_tenant_id` set.
  `otp_app` is `:defdo_auth_client` for every record: the vault's `otp_app` column is the
  OWNER namespace and part of the lookup key (`sdk.ex:267`, README "otp_app ownership"),
  so a single owner lets the library find any host's record; hosts set
  `config :defdo_vault, :caller_otp_app` to themselves and the library's writes pass
  `allow_cross_otp: true` only through `put/2` (documented). Missing → `{:error, :not_configured}`;
  any raise → `{:error, :not_configured}` + module-only log.
- `sites(tenant_ids)`: `[app.site | Enum.map(tenant_ids, &customer_site/1)]` keeping `{:ok, _}`,
  `Enum.uniq`; app record missing → start from `[]`. Deterministic, no VM memory.
- `put(%{vault_tenant_id: id}, attrs)`: the APP record = one `Consumer.upsert_secret/2` per code
  (`%{tenant_id: id, project_key:, code: "auth." <> k, content: %{"value" => v}, env:, otp_app: :defdo_auth_client}`,
  `allow_cross_otp: true`) inside `Defdo.Tenant.Context.with_context(id, fn -> … end)`
  (defdo_tenant 0.24.1 `context.ex:110`). `id` is the DEPLOYMENT.s own vault tenant — the
  tenant the install created (provision_web `tenant_id/1`) or, in dev/test, the
  `tenant_id` of the `config :defdo_vault, :credentials` keyword. It is NOT `auth.tenant`
  (the pinned estate IdP tenant, which is record CONTENT). This is the production writer
  too (host migration tasks and, later, the install flow call it), so it is never refused by env. Afterwards
  `Defdo.Vault.Runtime.refresh/0` when running. Missing optional keys are written as `""`. `put(%{tenant_id: id}, attrs)`: one record,
  content merged over the existing one.
- `introspection(ctx)`: `resolve(ctx)` → `%{site:, internal_api_token: Config.from_env([:introspection, :internal_api_token])}`;
  `{:error, _}` passes through. Never "first".

## Step 6 — Guide and capabilities

`guides/site.md`: the two record kinds, the codes table, the host wiring (`vault_set/2`
as a Runtime child after Repo and as a release `config_providers` entry; dev credentials
keyword with `transport: :local`), `put/2` (dev/test and customer records), `otp_app`
semantics, the "config names codes only" rule and `NotFromVault`. Capabilities row.

## Process map

Process map: no long-lived activity added or changed (the Runtime child is the host's;
its row is written by each host slice).

## Tests

- `env_test.exs`; `codes_test.exs` (`vault_values/0` has 15 entries, paths under the two
  keys).
- `site_test.exs`: app record from env (the Runtime's output shape, string values,
  `scopes` split, `service_client` built, extra → `raw`); missing required →
  `{:error, {:missing, ["auth.tenant"]}}`; `site:` without `vault_project` →
  `Site.NotFromVault`; `introspection(%{})`.
- `site/vault_test.exs` (fake `Defdo.Vault.Consumer`): customer record atom- and
  string-keyed payloads → same struct (guard: `normalise/1`); `:request` ctx without
  tenant → app record; raising consumer → `{:error, :not_configured}`, log has no
  secret; `put(%{tenant_id:}, …)` merges content; `put(%{vault_tenant_id: t}, …)` writes 15
  codes under `t` inside `with_context` and calls `Runtime.refresh/0` if running (guard:
  the loop over `Codes.keys/0`); `put(%{}, …)` with neither `vault_tenant_id` nor
  `tenant_id` → `{:error, :no_tenant}`;
  `sites(["t1","t2"])` deterministic.
- Property: `inspect/1` never contains either secret; `to_oauth_opts/1` has no
  `:client_secret` key when nil.

## Verification

```sh
grep -q '"defdo_vault"' mix.lock
grep -q '"defdo_tenant"' mix.lock
! grep -rn "Mix.env()" lib/
! grep -rn "mode: :static\|Site.Static" lib/
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
grep -q "def vault_set(" lib/defdo/auth_client/site.ex
grep -q "NotFromVault" lib/defdo/auth_client/site.ex
grep -q "service_client" lib/defdo/auth_client/site/client.ex
grep -q "Site" .ai/capabilities.md
test -f guides/site.md
```

## Acceptance criteria

- [ ] Vault-only: no static mode, `NotFromVault` enforced and tested.
- [ ] App record via Provider/Runtime set; customer record via Consumer under context;
      both normalise atom/string keys (tests).
- [ ] `put/2` writes the app record under an explicit vault tenant inside `with_context` and refreshes the Runtime (tests).
- [ ] Two defdo_vault gap issues filed and linked; guide + capabilities + CHANGELOG.
