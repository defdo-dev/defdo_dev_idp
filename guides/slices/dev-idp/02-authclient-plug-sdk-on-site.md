---
kind: implementation
serves: [P-01, P-05]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-sso-flow-test, defdo-exunit-quality-tests]
repo: defdo-dev/defdo_auth_client
---

# Slice 02 — Plug and SDK resolve through `Site`; the lazy dev guard

Work only inside `defdo_auth_client`. Read `00-conventions.md`.

## Ecosystem

- uses: this repo `AuthorizeCodeWithPKCE` `app_client/0` (`plug/authorized_code_with_pkce.ex:1428-1446`),
  `to_client/1` (`:1320-1330`), `SDK.merge_config/1` (`lib/defdo_auth_client_sdk.ex:1217`),
  `Defdo.AuthClient.Env` (slice 01). Verified 0.14.0 — re-locate with
  `grep -n "defp app_client\|defp to_client\|defp merge_config"`.
- gap: none.

## Goal

With no `resolve_client` and no `put_config/1`, the PKCE plug builds its client from
`Site.resolve(%{conn: conn})`; `SDK.introspect_credential/3` and `SDK.get_user_info/2`
take `site`/`internal_api_token` from `Site.introspection/1` when the caller passes none.
When `Env.current() == :dev`, the FIRST auth request (plug call or SDK introspection)
raises `DevSiteError` if the resolved site is not loopback and `Defdo.DevIdp` is not
loaded — unless the host states `allow_remote_site_in_dev: true` under `site:`.

## Preconditions

Slice 01 merged.

## Targets

- `lib/defdo/defdo_auth/plug/authorized_code_with_pkce.ex` (`app_client`, `resolve_client` default).
- `lib/defdo_auth_client_sdk.ex` (`merge_config/1`, `introspect_credential/3`, `get_user_info/2`).
- `lib/defdo/auth_client/dev_guard.ex`, `lib/defdo/auth_client/dev_site_error.ex` (new).
- `guides/phoenix-integration.md`, `guides/code-with-pkce.md`.

## Step 1 — Plug

`app_client/0` → `app_client/1` (conn): `get_config()` set → current branch (per-request
`put_config/1` stays as the test/escape hatch); else
`Site.resolve!(%{conn: conn}) |> Client.to_oauth_opts() |> CodeWithPKCE.new_client()`.
The `Config.from_env([:client])` branch is REMOVED. Default `resolve_client` (none
given) = `fn conn, _opts -> Site.resolve!(%{conn: conn}) end` (arity-2 hook form,
moduledoc `:resolve_client`). Every resolved client passes `DevGuard.check!/1` (Step 4)
before use. `NotConfigured` during a request → 500 + module-only log (the message has
examples, no secrets).

## Step 2 — SDK

`merge_config/1`: after `normalize_config_keys`, when `:site` or `:internal_api_token` is
absent, merge `Site.introspection(%{tenant_id: config[:tenant_id]})` (`{:ok, map}` →
merge; `{:error, _}` → leave absent so `CredentialIntrospection` reports the missing key
as today). `get_user_info/2` likewise for `:site`. Both call `DevGuard.check!/1` on the
site they end up with.

## Step 3 — Guides

Replace every `client: [...]` example with the `site:` block and add the `Env` lines
(`config :defdo_auth_client, :env, config_env()`). "Migrating from `client:`": the values move into the
vault app record (codes table in `guides/site.md`), written once by the host's
`Release.migrate_site_record/0` through `Site.put/2` (host slices 09–11); config keeps only
`site: [vault_project: "..."]`.

## Step 4 — The dev guard: lazy, on the first auth request

Why not at application start: a dependency's `Application.start/2` runs BEFORE the host's
Repo and vault are up, so `Site.sites/1` cannot be answered there in `:vault` mode (and
`Mix.env()` there is the dependency's compile env, not the host's — slice 01 Step 1).
The first auth request happens after everything is running, so the check is exact there
and still breaks a mis-wired dev host on its first login ("si se omite en dev se rompa").

```elixir
defmodule Defdo.AuthClient.DevGuard do
  @spec check!(String.t()) :: :ok
  def check!(site) when is_binary(site) do
    if Env.current() == :dev and remote?(site) and not opted_out?() and not dev_idp_loaded?() do
      raise Defdo.AuthClient.DevSiteError, site: site
    end
    :ok
  end
  defp dev_idp_loaded?, do: Code.ensure_loaded?(Defdo.DevIdp)   # the dep is absent from a host that omitted it: not loadable
  defp opted_out?, do: Config.from_env([:site, :allow_remote_site_in_dev]) == true
  defp remote?(site), do: URI.parse(site).host not in ["localhost", "127.0.0.1", "::1"]
end
```

Message: `:defdo_auth_client runs in :dev (config :defdo_auth_client, :env) against a
remote IdP (<site>) and defdo_dev_idp is not loaded. Add {:defdo_dev_idp, "~> 0.1",
organization: :defdo, only: [:dev, :test]} and configure it (guides/slices/dev-idp), or
state allow_remote_site_in_dev: true under site: to opt out explicitly.`

The guard runs once per resolved client (cheap: one `URI.parse`); no process, no boot
coupling. Recorded in `guides/site.md` "Dev guard".

## Process map

Process map: no long-lived activity added or changed.

## Tests

- Plug: app record in env (the Runtime's output shape, `vault_project:` present) + no
  `resolve_client` → redirect carries that `client_id`/`redirect_uri` (guard: `app_client/1`);
  only the legacy `client:` key set → `NotConfigured` raised; `site:` values WITHOUT
  `vault_project:` → `NotFromVault` raised (no-fallback, no-config-values proofs).
- SDK: `introspect_credential(tok, %{})` with `introspection:` configured hits
  `<site>/api/v1/introspect` (use the repo's existing HTTP stubbing: `grep -rn "Bypass\|Req.Test" test | head`).
- DevGuard (`:env` set to `:dev` in the test, restored on exit): remote site, dep absent
  → `DevSiteError` with the site in the message; loopback → `:ok`; opt-out → `:ok`;
  `:env` `:test` → `:ok`. "Dep absent" is the real state of this repo's test env
  (`defdo_dev_idp` is not a dep of `defdo_auth_client`), so `Code.ensure_loaded?` is false
  for real — no module stubbing. (The positive "dep present" case is proven in the dev
  IdP's integration test, slice 08.)

## Verification

```sh
! grep -rn "Mix.env()" lib/
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
grep -q "Site.resolve" lib/defdo/defdo_auth/plug/authorized_code_with_pkce.ex
! grep -q "Config.from_env(\[:client\])" lib/defdo/defdo_auth/plug/authorized_code_with_pkce.ex
grep -q "DevGuard.check!" lib/defdo/defdo_auth/plug/authorized_code_with_pkce.ex
grep -q "DevGuard.check!" lib/defdo_auth_client_sdk.ex
! grep -rn "client: \[" lib/
! grep -rn "client: \[" guides/
```

## Acceptance criteria

- [ ] No `client:` fallback in `lib/` or `guides/` (the `! grep` lines, scoped).
- [ ] Guard is request-time only (`! grep -rn "DevGuard" lib/defdo/auth_client/application.ex`).
- [ ] DevGuard tests by name; CHANGELOG marks the BREAKING config change and links `guides/site.md`.
