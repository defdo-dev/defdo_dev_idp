---
kind: implementation
---

# 00 — Conventions for the dev-login set

Read before any slice. Facts were computed from source on 2026-11-08 (defdo_auth_client
0.14.0, defdo_vault 0.21.2, defdo_tenant 0.24.1, bandit 1.13.1); re-locate with the grep
given before relying on a line number.

## Environment and build

- Elixir 1.20.4 / OTP 28 everywhere. Private Hex deps resolve with the org token
  (`load_defdo_hex`); never `mix hex.user auth`.
- The verify-slice VM has no internet: every dep is in `mix.lock` before the job runs.
- Release-validate per repo = `mix compile --warnings-as-errors && mix format --check-formatted
  && mix credo --strict && <that repo's tag-pipeline test line>`.
- **No `Mix.env()` in package code.** A dependency compiles under the HOST's `MIX_ENV`,
  but `Mix.env()` evaluated inside a dep at compile time is whatever the dep was compiled
  with and is unavailable at runtime in a release. Hosts state their env once:
  `config :defdo_auth_client, :env, config_env()` (in `config/config.exs`) and packages
  read `Defdo.AuthClient.Env.current/0`. `Mix.env()` is allowed only in `mix.exs`.
- **No env vars** (owner rule). Config files name vault project and record CODES only —
  never a site, an id, a tenant or a secret.

## Ownership

- `defdo_auth_client` owns the contract: `Defdo.AuthClient.Site` (where the IdP is, which
  client, which pinned tenant/connection, the service client), `Defdo.AuthClient.Identity`
  (who is signed in), the PKCE plug and the SDK.
- `defdo_dev_idp` owns the mock IdP, the seeder behaviour, the seed task, the gate script.
- Hosts own: their vault project and records (written through `Site.put/2` or the seed
  task), their `Defdo.Vault.Runtime` child, their seeder, authorization (roles →
  permissions), their pipelines.
- Nothing host-specific lives in a package; nothing auth-resolving lives in a host.

## The homologated contract (slices 01–03)

**One source: defdo_vault.** Two record kinds, one reader.

1. **The app record** — pinned per deployment (owner rule 2026-09-22: apps never get a
   tenant per instance; they live in the estate IdP tenant, pinned by config, never
   chosen by a request or a DB row). Read WITHOUT request context through the vault's
   runtime fetcher: `Defdo.Vault.Provider` at release boot and `Defdo.Vault.Runtime` as a
   host child after Repo (`deps/defdo_vault/lib/defdo/vault/provider.ex` moduledoc:
   `values: [{path, code}]`, strings; `runtime.ex`: re-resolves the set, `refresh/2`
   synchronous). Dev/test credentials: `config :defdo_vault, :credentials` keyword with
   `transport: :local, tenant_id: <the app's vault tenant>` (`credentials.ex` moduledoc:
   keyword allowed in `:dev`/`:test` only; `Transport.Local` resolves through the embedded
   SDK and needs the Repo, hence the child order). The codes, flat strings, project =
   the host's vault project:

   | code | config path under `[:defdo_auth_client, Defdo.AuthClient, :site]` |
   |---|---|
   | `auth.site` | `:site` |
   | `auth.tenant` | `:tenant` (the pinned estate IdP tenant id) |
   | `auth.connection` | `:connection` (the pinned IdP connection id) |
   | `auth.client_id` / `auth.client_secret` | `:client_id` / `:client_secret` (login client) |
   | `auth.redirect_uri` | `:redirect_uri` |
   | `auth.scopes` | `:scopes` (space-joined) |
   | `auth.registration_type` / `auth.connection_type` | same names (optional) |
   | `auth.authorize_url` / `auth.token_auth_method` | same names (optional) |
   | `auth.service_client_id` / `auth.service_client_secret` / `auth.service_scopes` | `:service_client_id` … (the M2M client, second registration) |
   | `auth.internal_api_token` | `[:defdo_auth_client, Defdo.AuthClient, :introspection, :internal_api_token]` |

   The host's ONLY config lines are the declaration of that set:

   ```elixir
   # config/runtime.exs (and the release's config_providers)
   config :defdo_auth_client, Defdo.AuthClient, site: [vault_project: "gateway"]   # codes are fixed by the contract
   # lib/<host>/application.ex, after Repo:
   {Defdo.Vault.Runtime, Defdo.AuthClient.Site.vault_set("gateway", env)}          # slice 01 builds the values list
   ```

2. **Customer tenant records** — one vault record per tenant (code `defdo_auth_client`,
   content map, same keys as above without the `auth.` prefix), read under
   `Defdo.Tenant.Context` through `Defdo.Vault.Consumer.resolve_secret/3`, written with
   `Consumer.upsert_secret/2` (both verified `consumer.ex:82-100`; the gateway already
   calls them). `Site.resolve(%{tenant_id: id})` reads these; `Site.resolve(%{})` reads
   the app record.

`Defdo.AuthClient.Site`: `resolve/1`, `resolve!/1`, `sites/1` (the app site plus the
sites of the given tenant ids — there is no list API in defdo_vault 0.21, recorded gap),
`put/2` (`%{}` ctx → app record codes via `Consumer.upsert_secret` under the credentials
tenant, then `Defdo.Vault.Runtime.refresh/0`; `%{tenant_id:}` → customer record),
`introspection/1` (explicit ctx, never "first"). `Defdo.AuthClient.Identity.from_session/1`
is the one way to read the current user. The dev IdP calls ONLY these. A host that
needs something else improves the contract in `defdo_auth_client`.

**Tests** (packages and hosts): the app record is the vault's OUTPUT, so a test may put it
in application env directly (`Application.put_env(:defdo_auth_client, Defdo.AuthClient, site: [site: …])`)
— that is what `Defdo.Vault.Runtime` would have written; customer records use a fake
`Defdo.Vault.Consumer` (`config :defdo_vault, :consumer, Fake`, the `impl/0` seam at
`consumer.ex:71`). Host `config/*.exs` files never contain those values; Gate 4 (slice 12)
greps for them.

## The client wire contract (quoted from defdo_auth_client 0.14.0; unchanged by 01–03)

| Need | Client code | What the dev IdP must do |
|---|---|---|
| Authorize | `strategy/auth_code_pkce.ex` `authorize_url/2` (`:12-24`): `response_type=code`, `client_id`, `redirect_uri`, `state`, `code_challenge` = `Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)` with `code_challenge_method=S256` (`:67-83`), host params (`scope`, `prompt`, `registration_type`, `connection_type` via `:authorize_params`); path = oauth2 2.1.1 default `/oauth/authorize` or the record's `authorize_url` | `GET /oauth/authorize` and alias `GET /openid/authorize` (defdo_auth router `pipeline :legacy_openid_authorize`, `route: "/openid/authorize", successor: "/oauth/authorize"`); 302 `redirect_uri?code=…&state=…`; `prompt=none` without a dev session → `?error=login_required&state=…` (plug retries interactively: `@interactive_retry_errors ~w(login_required interaction_required)`) |
| Token | `get_token/3` (`:30-49`): `grant_type=authorization_code`, `code`, `redirect_uri`, `code_verifier`; client auth per `:token_auth_method` (`:post` default, `:basic`); path default `/oauth/token`; `accept: application/json` | `POST /oauth/token` → `{"access_token","token_type":"Bearer","expires_in":3600,"scope":"…","id_token":"…"}` |
| Callback | plug `call/2` (`grep -n '"sub"' plug/authorized_code_with_pkce.ex`): needs `%AccessToken{expires_at}` and userinfo `%{"sub" => _}`; writes `:user_token` + `:live_socket_id` (`plug/session_stores/default.ex`), caches profile in `:defdo_auth_user_profile` under `user_cache_key(client, sub)` (scoped to the issuing client) | `expires_in` present; userinfo has `sub` |
| Userinfo | `adapter/auth_code_pkce.ex:96` `GET /openid/userinfo` Bearer | `{"sub","email","email_verified":true,"name","preferred_username","tenant_id","roles":[…],"scope"}` |
| Token introspection | `adapter/auth_code_pkce.ex:52-65` `POST /oauth/introspect` form `token`,`client_id`,`client_secret` → `%{"active","scope"}` | answer both, `scope` string |
| Credential introspection | `credential_introspection.ex:56,110-125` `POST /api/v1/introspect` JSON `{"token"}`, header `x-internal-token`, config `:site` + `:internal_api_token` | require the header; `{"active","sub","scope","scopes","tenant":{"id"},"tenant_id","client_id"}` or `{"active":false}` |
| Discovery / JWKS | not called by 0.14.0; owner requires them | `/.well-known/openid-configuration`, `/.well-known/jwks.json` |

Host readers (gateway `AdminScope.tenant_id/1`, `scope_list/1`) accept `tenant.id` /
`tenant` / `tenant_id` and `scope` string / `scopes` list; the dev IdP sends all.

## Profiles (dev IdP)

```elixir
config :defdo_dev_idp,
  enabled: true, host: :defdo_gateway, port: 4100,
  client: [id: "dev-gateway", secret: "dev-gateway-secret"],   # dev literals, worthless outside the dev IdP; the seed task writes them INTO the vault
  internal_api_token: "dev-internal-token",
  redirect_uri: "http://localhost:4000/oauth2/defdo_auth",
  app_record_extra: %{},                                        # extra codes for records the seed writes (string keys), declared, never computed
  profiles: [
    %{key: :operator, label: "Operator · Defdo Red", role: "operator", tenant: "dev-tenant",
      tenant_id: "00000000-0000-4000-8000-000000000001", scopes: ~w(openid profile ai:admin)},
    %{key: :customer, label: "Customer · Acme", role: "customer", tenant: "acme",
      tenant_id: "00000000-0000-4000-8000-000000000002", scopes: ~w(openid profile)}
  ]
```

Derived: `sub = "dev-" <> role <> "-" <> tenant`, `email = role <> "@" <> tenant <> ".dev.defdo"`,
`name = label`, `tenant_id` defaults to `tenant`. The FIRST profile's `tenant_id` is the pinned estate tenant: the seed writes it as the app
record's `auth.tenant` (connection `"dev-connection"`); profiles with another `tenant_id`
are customer tenants and get customer records.

## Tenant stack (every slice)

| Role | Package (locked) | API quoted |
|---|---|---|
| creates | defdo_tenant_provision 0.3.0 | `Defdo.Tenant.Provision.run(params, source:, idempotency_key:, preflight:, steps:)` (`provision.ex:112`); `Step.new(name, :transactional \| :best_effort, fun)` |
| installs (first run; untouched in this set) | defdo_tenant_provision_web 0.5.0 | `Defdo.Tenant.ProvisionWeb.Adapter` (`adapter.ex:49-78`) — see product.md Out of scope |
| resolves at the edge | defdo_tenant_plug 0.3.1 | `plug Defdo.TenantPlug.Plug, resolver: [{:host}, {:session}], assign_key:, required?:, put_session: true` (`plug.ex:8-25`); `on_mount {Defdo.TenantPlug.LiveView, :default \| {:optional, opts}}` (`live_view.ex:9-17`, session key `"tenant_id"`); resolvers `host subdomain header path session static connect_*` |
| protects across processes | defdo_tenant_boundary 0.7.0 | `Defdo.Tenant.Boundary.Task.async/1`, `Boundary.Oban.insert/3`, `use Boundary.Worker`, `Boundary.Cache.key/1` (README) |
| holds context | defdo_tenant 0.24.1 | `Defdo.Tenant.Context.with_context/2` (`context.ex:110`), `Context.tenant_id/0` (`:98`) — used by the packages above and by `Site` for per-tenant vault reads |

Rules: tenant rows are created only through provision(_web); the request tenant is
established only by `Defdo.TenantPlug` (and restored in LiveView by its `on_mount`);
anything that crosses a process uses a `Boundary` wrapper; tenant ids are never threaded
as arguments past the edge; `skip_tenant_id` only at the host.s named registry edge.

## Language and framework rules

- Tagged tuples at boundaries; `raise` only for programmer/config errors.
- Dev IdP pages: plain string templates, `Plug.HTML.html_escape/1` on every value.
- Never `inspect/1` a token, code or secret into a log; log counts, keys, module names.
- Pre-commit gate `mix credo --strict`: complexity ≤ 9, no single-branch `cond`.

## Tests

- A test must fail when its guard is removed: every slice names the guard.
- Package HTTP tests use `Req` against the server on port 0 (`ThousandIsland.listener_info/1`,
  `deps/thousand_island/lib/thousand_island.ex:219`, thousand_island 1.6.0).
- Properties (`stream_data`) for the code/token store and PKCE.

## Verification loop (every slice; one command per line)

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

## Git

Branch `slice/dev-login-NN-<name>`; one slice per PR; no attribution trailers, no
session links; never commit `_build`, `deps`, or any key material (there is none: the
dev IdP's signing key lives in memory).
