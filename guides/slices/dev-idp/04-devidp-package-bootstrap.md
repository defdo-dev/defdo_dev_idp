---
kind: implementation
serves: [P-05, P-06]
skills: [defdo-platform, defdo-package-architect, defdo-exunit-quality-tests]
repo: defdo-dev/defdo_dev_idp
---

# Slice 04 — Package bootstrap: host-supervised server, profiles, explicit boot states

Work only inside `defdo_dev_idp` (empty repo created by the owner). Read `00-conventions.md`.

## Ecosystem

- uses: bandit ~> 1.13 (`ip: {127,0,0,1}`; bound port via `ThousandIsland.listener_info/1`,
  `deps/thousand_island/lib/thousand_island.ex:219`, verified thousand_island 1.6.0 /
  bandit 1.13.1: `{:ok, {ip, port}} | :error`, called with the pid `Bandit.start_link/1` returns).
- uses: plug ~> 1.16, jason ~> 1.4, credo ~> 1.7 (dev/test).
- uses: defdo_auth_client@0.15 — `Defdo.AuthClient.Site.sites/1`, `Defdo.AuthClient.Env.current/0`
  (slice 01). The boot check reads nothing else.
- uses: defdo_vault@0.21.2 — the HOST runs `Defdo.Vault.Runtime` before this child; the
  ordering rule in Step 5.
- gap: none.

## Goal

A host adds the dep (`only: [:dev, :test]`), `config :defdo_dev_idp, enabled: true` in its
`config/dev.exs`, and ONE child `Defdo.DevIdp` in its supervision tree AFTER its Repo and
vault. The server starts on `127.0.0.1:<port>` in one of two states: **ready** (every
configured site points at it) or **unseeded** (no record yet: every page answers a 503
"run `mix defdo_dev_idp.seed`" and a warning is logged) — so a fresh database can boot
and be seeded. It REFUSES to start (`BootError`) only when a configured site points
elsewhere or the config block is missing. Non-loopback peers get 404.

## Preconditions

Owner created `defdo-dev/defdo_dev_idp`; `defdo_auth_client` 0.15.0 published; this set
copied to `guides/slices/dev-idp/` as the first commit.

## Targets

- `mix.exs`, `.tool-versions`, `.formatter.exs`, `.credo.exs`, `.woodpecker/ci.yml`
  (copies from `defdo_auth_client`, app renamed, `labels: platform: linux/amd64`),
  `README.md`, `CHANGELOG.md`, `guides/PROCESS_MAP.md`.
- `lib/defdo/dev_idp.ex`, `lib/defdo/dev_idp/config.ex`, `lib/defdo/dev_idp/profile.ex`,
  `lib/defdo/dev_idp/boot.ex`, `lib/defdo/dev_idp/boot_error.ex`, `lib/defdo/dev_idp/state.ex`,
  `lib/defdo/dev_idp/web/router.ex`, `lib/defdo/dev_idp/web/loopback_only.ex`,
  `lib/defdo/dev_idp/web/unseeded.ex`, `lib/defdo/dev_idp/web/pages.ex`,
  `lib/defdo/dev_idp/web/discovery.ex`.

## Step 1 — Mix project

```elixir
def project do
  [app: :defdo_dev_idp, version: "0.1.0", elixir: "~> 1.20",
   elixirc_paths: elixirc_paths(Mix.env()),            # the package's OWN test/support; the only Mix.env() allowed, and only in mix.exs
   start_permanent: false, deps: deps(),
   description: "Dev-only mock IdP speaking the defdo_auth OAuth2/OIDC subset, against Defdo.AuthClient.Site",
   package: [organization: "defdo", licenses: ["Proprietary"], files: ~w(lib scripts mix.exs README.md CHANGELOG.md)]]
end
def application, do: [extra_applications: [:logger, :crypto, :public_key]]   # NO mod: the host supervises Defdo.DevIdp
defp deps do
  [{:bandit, "~> 1.13"}, {:plug, "~> 1.16"}, {:jason, "~> 1.4"}, {:jose, "~> 1.11"},
   {:defdo_auth_client, "~> 0.15", organization: :defdo},
   {:req, "~> 0.5", only: :test}, {:stream_data, "~> 1.1", only: :test},
   {:credo, "~> 1.7", only: [:dev, :test], runtime: false}]
end
```

Decision (round 2): **no package `mod:`**. A dependency's `Application.start/2` runs
before the host's Repo/vault, so it cannot evaluate `Site.sites/1` in `:vault` mode and
cannot know the host env. The host places `Defdo.DevIdp` after Repo and vault in its
children; the host already owns that list. Enforcement when a host omits it is the
client's lazy `DevGuard` (slice 02), which does not depend on boot order.
`mix deps.get` yourself; commit `mix.lock`.

## Step 2 — Config and profile

```elixir
# host config/dev.exs (test.exs sets nothing: tests start the server with explicit opts)
config :defdo_dev_idp,
  enabled: true, host: :defdo_gateway, port: 4100,
  client: [id: "dev-gateway", secret: "dev-gateway-secret"],
  internal_api_token: "dev-internal-token",
  redirect_uri: "http://localhost:4000/oauth2/defdo_auth",
  provision: [repo: Defdo.Gateway.Repo],              # slice 07: tenants through defdo_tenant_provision
  site_record_extra: %{},                             # slice 07
  profiles: [ ... ]                                   # 00-conventions.md
```

`Config.fetch!/0` reads `Application.get_all_env(:defdo_dev_idp)`; required: `enabled: true`
(anything else → `{:error, :disabled}` and `Defdo.DevIdp.start_link/1` returns `:ignore`,
so a host may keep the child line in `test.exs`-less suites harmlessly), `host`, `port`,
`client`, `internal_api_token`, `redirect_uri`, `profiles`. `Profile.new!/1` as before
(`sub`, `email`, `name`, `tenant_id` default = `tenant`, regex validation, unique keys).

## Step 3 — Boot.check/1: three outcomes, one source

```elixir
@spec check(Config.t()) :: {:ok, :ready} | {:ok, :unseeded} | {:error, {:site_mismatch, [String.t()], String.t()}}
def check(config) do
  expected = ["http://localhost:#{config.port}", "http://127.0.0.1:#{config.port}"]
  tenant_ids = config.profiles |> Enum.map(& &1.tenant_id) |> Enum.uniq()
  sites = Defdo.AuthClient.Site.sites(tenant_ids)          # app site + the customer tenants' sites
  case {sites, Enum.reject(sites, &(normalize(&1) in expected))} do
    {[], _} -> {:ok, :unseeded}
    {_, []} -> {:ok, :ready}
    {_, remote} -> {:error, {:site_mismatch, remote, hd(expected)}}
  end
end
```

The chicken-and-egg is broken explicitly: a fresh DB has no record → `:unseeded` → the
server starts and the host boots → `mix defdo_dev_idp.seed` (which uses `app.start`)
writes the records → `Defdo.DevIdp.recheck/0` (called by the seed task, slice 07) flips
the state to `:ready`; every request also re-checks when the state is `:unseeded` (one
`Site.sites/1` per request in that state only). `Site.sites/1` raising (vault not
reachable) → `BootError` with `{:site_lookup_failed, exception_module}`: a host that put
the child BEFORE its Repo sees exactly that message, which names the fix ("place
`Defdo.DevIdp` after your Repo and vault children").

## Step 4 — Supervisor, server, loopback plug, unseeded page, index, discovery

`Defdo.DevIdp.start_link(opts)`: `Config.fetch!()` merged with `opts` (tests pass
`port: 0, enabled: true, profiles: …`) → `{:error, :disabled}` → `:ignore`; `Boot.check/1`
→ `{:error, reason}` → raise `BootError`; `{:ok, state}` → start children
`Defdo.DevIdp.State` (Agent holding `:ready | :unseeded`), `Defdo.DevIdp.Store` (slice 05;
stub now), `{Bandit, plug: {Web.Router, config}, ip: {127,0,0,1}, port: port, scheme: :http}`.
Log: `defdo_dev_idp listening on http://localhost:<port> for :<host> (<n> profiles, <state>)`;
in `:unseeded` also `Logger.warning("defdo_dev_idp: no Site record yet — run mix defdo_dev_idp.seed")`.
`Defdo.DevIdp.port/0` via `ThousandIsland.listener_info/1`; `Defdo.DevIdp.recheck/0`
re-runs `Boot.check/1` and updates `State`.

`Web.Router`: `plug LoopbackOnly` → `plug Unseeded` (when `State` is `:unseeded`, re-check
once; still unseeded → 503 HTML/JSON by `accept`: "Dev IdP for :<host> has no Site
record. Run `mix defdo_dev_idp.seed`." and halt; `/` is exempt so the index shows the
state) → `:match` → `Plug.Parsers` → `:dispatch`.

`LoopbackOnly`: `remote_ip in [{127,0,0,1}, {0,0,0,0,0,0,0,1}, {0,0,0,0,0,65535,32512,1}]`
else 404 halt. Index and discovery as in round 1 (`Pages.index/2` shows the state and
"Sign out everywhere"; discovery's nine keys + `scopes_supported`).

## Step 5 — README "Install in a host"

```elixir
# mix.exs
{:defdo_dev_idp, "~> 0.1", organization: :defdo, only: [:dev, :test]}
# config/dev.exs: the :defdo_dev_idp block (enabled: true) + Defdo.AuthClient `site:` + `config :defdo_auth_client, :env, :dev`
# lib/<host>/application.ex — AFTER Repo and vault children:
children = [MyHost.Repo, {Defdo.Vault.Runtime, Defdo.AuthClient.Site.vault_set("my_host", env)}, Defdo.DevIdp, MyHostWeb.Endpoint]
```

`Defdo.DevIdp` is a bare module atom in the list: no remote call, so a prod compile emits
no warning and the child spec is only looked up at runtime — and the module is absent
there, so a prod host that forgot to remove it fails at boot with
`UndefinedFunctionError Defdo.DevIdp.child_spec/1` — acceptable and loud; the gate
(slice 08) catches it earlier anyway. In `:test` the host sets no `:defdo_dev_idp` config
→ `start_link` returns `:ignore`.

## Process map

| Activity | Where it hangs | Starts after | Stopping it stops | Owns | Alive? |
|---|---|---|---|---|---|
| Dev IdP server (`Defdo.DevIdp`: `State` + `Store` + Bandit) | HOST application children, after Repo and vault, dev only (`enabled: true`); tests `start_supervised!` | `Boot.check/1` returned `{:ok, _}` | all dev logins | listener, codes/tokens/sessions, boot state | `Process.whereis(Defdo.DevIdp)` |

## Tests

- `config_test.exs`: missing block → `BootError` message quotes `config :defdo_dev_idp` and
  the host; `enabled: false` → `start_link` `:ignore`.
- `profile_test.exs` (as round 1, plus `tenant_id`).
- `boot_test.exs` (app record put in env with `vault_project:`, the Runtime's output shape): remote site → `{:error, {:site_mismatch, _, _}}`
  and `start_link` raises `BootError` with no process left; matching → `{:ok, :ready}`;
  a `Site` impl stub returning `[]` → `{:ok, :unseeded}`; a stub raising → `BootError`
  `{:site_lookup_failed, _}` whose message says "after your Repo".
- `unseeded_test.exs`: start with the `[]` stub → `GET /oauth/authorize?...` is 503 with
  "mix defdo_dev_idp.seed"; `GET /` is 200 and says `unseeded`; after switching the stub
  to a matching site and `recheck/0`, the same request is no longer 503 (guard: the
  re-check).
- `router_test.exs`: index escaping; discovery keys; bound to `127.0.0.1`.
- `loopback_only_test.exs`: `remote_ip: {10,0,0,5}` → 404 halted; `{127,0,0,1}` passes.

## Verification

```sh
grep -q '"bandit"' mix.lock
grep -q '"defdo_auth_client"' mix.lock
test -f .credo.exs
! grep -rn "Mix.env()" lib/
! grep -q "mod:" mix.exs
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
grep -q "unseeded" lib/defdo/dev_idp/boot.ex
grep -q "Site.sites(" lib/defdo/dev_idp/boot.ex
grep -q "LoopbackOnly" lib/defdo/dev_idp/web/router.ex
grep -q "Dev IdP server" guides/PROCESS_MAP.md
```

## Acceptance criteria

- [ ] No `mod:`; no `Mix.env()` in `lib/`; host-supervised child documented with the ordering rule.
- [ ] Three boot outcomes tested by name; unseeded state serves the 503 page and recovers after `recheck/0`.
- [ ] Boot reads only `Site.sites/1` (grep); loopback enforced twice and tested.
- [ ] `mix.lock` committed; PROCESS_MAP row present.
