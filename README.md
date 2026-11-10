# defdo_dev_idp

A dev-only mock IdP. It speaks the subset of the `defdo_auth` OAuth2/OIDC flow that
`defdo_auth_client` uses, against the `Defdo.AuthClient.Site` contract, so a defdo app
signs in locally through its unchanged plugs. A production build carries none of it.

Status: slices 04–07 of the dev-login set (`guides/slices/dev-idp/`). The server, every
endpoint and the seed task are in place. The release gate arrives in slice 08.

## Install in a host

```elixir
# mix.exs
{:defdo_dev_idp, "~> 0.1", organization: :defdo, only: [:dev, :test]}
```

```elixir
# config/config.exs
config :defdo_auth_client, :env, config_env()

# config/dev.exs — test.exs sets nothing: tests start the server with explicit options
config :defdo_dev_idp,
  enabled: true,
  host: :my_host,
  port: 4100,
  client: [id: "dev-my-host", secret: "dev-my-host-secret"],
  internal_api_token: "dev-internal-token",
  redirect_uri: "http://localhost:4000/oauth2/defdo_auth",
  profiles: [
    %{key: :operator, label: "Operator · Defdo Red", role: "operator", tenant: "dev-tenant",
      tenant_id: "00000000-0000-4000-8000-000000000001", scopes: ~w(openid profile)}
  ]
```

```elixir
# lib/my_host/application.ex — AFTER the Repo and vault children
children = [
  MyHost.Repo,
  {Defdo.Vault.Runtime, Defdo.AuthClient.Site.vault_set("my_host", env)},
  Defdo.DevIdp,
  MyHostWeb.Endpoint
]
```

The values under `client:` and `internal_api_token:` are dev literals. They are worthless
outside the dev IdP.

### Why the order matters

The package has no application callback module. A dependency's application starts before
the host's Repo and vault, so it could not read the site records. The host supervises
`Defdo.DevIdp` and places it after both. A host that places it earlier gets a
`Defdo.DevIdp.BootError` saying exactly that.

`Defdo.DevIdp` is a bare module in the children list, so a production compile emits no
warning. The module is absent in production: a host that forgot to remove the line fails
at boot with `UndefinedFunctionError Defdo.DevIdp.child_spec/1`.

## Boot states

| State | When | What you see |
|---|---|---|
| `ready` | every configured site points at this dev IdP | the server answers normally |
| `unseeded` | no site record exists yet (a fresh database) | the index works; every other page is 503 "run `mix defdo_dev_idp.seed`" |
| refused | a site points at another IdP, the config block is incomplete, or the records cannot be read | `Defdo.DevIdp.BootError`; the host does not boot |

Without `enabled: true` the child returns `:ignore`.

An unseeded server re-checks on each request and through `Defdo.DevIdp.recheck/0`, so it
becomes `ready` as soon as the records exist.

## Safety rules

- The listener binds `127.0.0.1`, and every request from a non-loopback peer gets 404.
- The server never starts while a site record points at a real IdP.
- It declares itself with the mark `defdo-dev-idp` (field `defdo_idp_mark`).
  defdo_auth_client refuses a marked identity provider outside `:dev` and `:test`.
  The mark is self-declared: it catches a mistake, it does not stop an attacker.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

Private dependencies resolve with the organization read token.

## Seeding

```sh
mix defdo_dev_idp.seed
```

Add it to the host's setup alias, after the database exists:

```elixir
setup: ["deps.get", "ecto.setup", "defdo_dev_idp.seed", "assets.setup", "assets.build"]
```

The task needs the host's Repo for tenant provisioning:

```elixir
config :defdo_dev_idp, provision: [repo: MyHost.Repo]
```

On a fresh database the dev IdP starts `unseeded`. The task then:

1. provisions one tenant per distinct profile tenant through `Defdo.Tenant.Provision.run/2`;
2. writes the app `Site` record under the dev vault tenant (`config :defdo_vault, :credentials`);
3. writes one customer `Site` record per other profile tenant;
4. re-checks the dev IdP, which becomes `ready`.

It prints one line per step. A second run prints `unchanged` on every line and writes
nothing.

Rules:

- Records are written only through `Defdo.AuthClient.Site.put/2`, the same writer hosts
  use for their own records. There is no second record shape.
- A record that points at another site is never overwritten; the task stops with an error.
- The task refuses to run unless `config :defdo_auth_client, :env` is `:dev` or `:test`.
- Sample data is invented (`Defdo Red (sample)`, `Acme (sample)`). Never seed a real
  customer, email or phone.

### Deterministic tenant ids (open gap)

The task passes each profile's `tenant_id` to `Provision.run/2` as the `"tenant_id"`
param. Whether the tenant is created with that id depends on the host's provisioning
adapters. This is checked per host when the host adopts the dev IdP.

### The dev service client

The seed also records a service client, `<client id>-svc` with secret
`<client secret>-svc`. It mints machine tokens with `grant_type=client_credentials`
and the app record's service scopes (`api:admin` by default).
