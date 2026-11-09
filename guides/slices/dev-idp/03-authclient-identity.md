---
kind: implementation
serves: [P-01, P-02]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-liveview-elm-state, defdo-exunit-quality-tests]
repo: defdo-dev/defdo_auth_client
---

# Slice 03 — `Defdo.AuthClient.Identity`: the one way to read the current user

Work only inside `defdo_auth_client`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_tenant_plug@0.3.1 — `Defdo.TenantPlug.LiveView` `on_mount` runs BEFORE
  `LiveHook` in every host `live_session` (documented in the guide): identity resolution
  happens inside the request tenant context the edge established.
- uses: this repo `Defdo.DefdoAuth.Plug.SessionStores.Default` (`:user_token`,
  `plug/session_stores/default.ex`, verified 0.14.0), the caches
  `:defdo_auth_user_profile` / `:defdo_auth_user_client` written by the plug callback
  (`plug/authorized_code_with_pkce.ex:287-305`), `SDK.get_user_info/2`
  (`lib/defdo_auth_client_sdk.ex:590`), `Site` (slice 01).
- replaces (hosts, slices 09–11): cms `Defdo.Cms.Auth.DefaultCurrentUserAdapter`
  (`lib/defdo_cms/auth/default_current_user_adapter.ex`), my_mvno
  `Defdo.MyMvno.Authz.SessionActorResolver` (`lib/my_mvno/authz/session_actor_resolver.ex`),
  theme_hub `Plug.StudioAuth` subject read, gateway `AdminScope.resolve/1` token read.
- gap: none.

## Goal

A host reads the signed-in person with one call in a controller/plug
(`Identity.from_conn/1`), one hook in a `live_session`
(`on_mount {Defdo.AuthClient.LiveHook, :identity}` / `:require_identity`), and gets one
struct: `sub`, `email`, `name`, `tenant_id`, `roles`, `scopes`, `raw`. Authorization
(what the roles mean) stays in the host.

## Preconditions

Slices 01, 02 merged.

## Targets

- `lib/defdo/auth_client/identity.ex` (new), `lib/defdo/auth_client/plug/identity.ex`
  (new, under the existing `if Code.ensure_loaded?(Plug)` pattern),
  `lib/defdo/auth_client/live_hook.ex` (new, `if Code.ensure_loaded?(Phoenix.LiveView)`).
- `guides/phoenix-integration.md`: the hook and plug usage; `.ai/capabilities.md` row.

## Step 1 — The struct and resolution

```elixir
defmodule Defdo.AuthClient.Identity do
  defstruct [:sub, :email, :name, :tenant_id, roles: [], scopes: [], raw: %{}]
  @type t :: %__MODULE__{...}

  @spec from_session(map()) :: {:ok, t()} | {:error, :no_session | :expired | :not_configured}
  def from_session(session) do
    with {:ok, user_token} <- fetch_user_token(session),          # "user_token" or :user_token (both spellings, as SessionStores.Default reads)
         {:ok, profile} <- cached_or_fetched_profile(user_token, session) do
      {:ok, from_profile(profile)}
    end
  end

  @spec from_conn(Plug.Conn.t()) :: {:ok, t()} | {:error, term()}   # get_session/1 then from_session/1
  @spec from_profile(map()) :: t()
end
```

`cached_or_fetched_profile/2`: `Cachex.get(:defdo_auth_user_profile, user_token)` →
hit → profile. Miss → the access token: the plug caches a credential-free client under
`:defdo_auth_user_client` (`credential_free_client/1`, `:302`) — read it, call
`SDK.get_user_info(client.token.access_token, %{site: client.site})`, re-cache with the
same TTL discipline (`profile_cache_ttl/1`, re-locate), else `{:error, :expired}`. No
`Cachex.get!` (raises when the cache is not running — the application moduledoc at
`application.ex:90` explains why).

`from_profile/1`: `sub` ← `"sub"`; `email` ← `"email"`; `name` ← `"name"` || `"preferred_username"`;
`tenant_id` ← `"tenant_id"` || `get_in(["tenant", "id"])`; `roles` ← `"roles"` (list of
strings, default `[]`); `scopes` ← `"scope"` split or `"scopes"` list; `raw` ← the profile.
These are the keys the hosts read today (my_mvno `Roles.explicit_roles_from_user/1`
reads — check the key with `grep -n "def explicit_roles_from_user" -A10 lib/my_mvno/auth/roles.ex`
in slice 10; if it reads another key, add it to `raw` consumers there, not here).

## Step 2 — Plug

`Defdo.AuthClient.Plug.Identity`: `init(opts)` (`:assign_as`, default `:current_identity`;
`:require`, default `false`; `:on_missing`, `{:redirect, path} | {:status, 401}`), `call/2`
assigns `{:ok, id}` → `id`, else `nil`, and when `require: true` halts per `on_missing`.

## Step 3 — LiveView hook

```elixir
def on_mount(:identity, _params, session, socket)            # assigns :current_identity or nil, always :cont
def on_mount({:require_identity, opts}, _params, session, socket)  # :halt + redirect(to: opts[:login_path] || "/oauth2/defdo_auth") when missing
```

`LiveHook` is pure over `session` (no conn), so hosts' `live_session` lists use it the
way my_mvno uses `{Hook.Actor, {:with_actor, …}}` today.

## Step 4 — Guide and capabilities

Document: "authorization stays yours — map `identity.roles`/`identity.tenant_id` to your
permissions; never read the session key or the cache directly." Capabilities row
"Identity — replaces: per-host session/user_token readers and userinfo refetchers".

## Process map

Process map: no long-lived activity added or changed.

## Tests

- `identity_test.exs`: cached profile → struct fields; both session key spellings;
  missing token → `{:error, :no_session}`; cache miss + client cached → refetch (stub
  the userinfo endpoint) and re-cache (guard: the refetch); cache miss + no client →
  `{:error, :expired}`; cache not running → `{:error, :expired}` not a raise.
- Plug and hook tests with `Plug.Test` / `Phoenix.LiveViewTest` session maps: require
  halts with redirect; non-require continues with `nil`.

## Verification

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
grep -q "defmodule Defdo.AuthClient.Identity do" lib/defdo/auth_client/identity.ex
grep -q "def on_mount({:require_identity" lib/defdo/auth_client/live_hook.ex
! grep -rn "Cachex.get!" lib/defdo/auth_client/identity.ex
```

## Acceptance criteria

- [ ] Struct, plug and hook exist; tests by name; no `Cachex.get!`.
- [ ] Guide section present; capabilities row present.
- [ ] CHANGELOG entry; with slices 01–02 this is `defdo_auth_client` 0.15.0 (owner tags).
