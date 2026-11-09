---
kind: implementation
serves: [P-01, P-02, P-03, P-07]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-tenant-edge-contract, defdo-tenant-platform-kit, defdo-liveview-elm-state]
repo: defdo-dev/defdo_my_mvno
---

# Slice 10d — my_mvno: tenant at the edge with `defdo_tenant_plug`, `Identity` everywhere

Work only inside `defdo_my_mvno`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_tenant_plug@0.3.1 — `plug Defdo.TenantPlug.Plug, resolver: [{:host}, {:session}], assign_key: :current_tenant, required?: true, put_session: true`
  (`plug.ex:8-25`, `live_view.ex:49-51`) BEFORE the PKCE plug in every browser pipeline;
  `on_mount {Defdo.TenantPlug.LiveView, :default}` first in every `live_session`
  (`live_view.ex:9-17`, session key `"tenant_id"`). Resolver `{:host}` replaces the
  host→tenant half of `lib/my_mvno/auth/tenant_resolver.ex`; if my_mvno needs a
  resolution the chain lacks (e.g. a domain table lookup), that is a custom resolver
  module exporting `resolve/2` (`plug.ex:203`) in the HOST, which the package allows.
- uses: defdo_auth_client@0.15 `Identity.from_session/1`, `Plug.Identity`, `LiveHook`
  (slice 03). The profile cache key is already scoped to the issuing client
  (`user_cache_key(client, sub)`, plug `:297`), so a tenant's client never shares a
  cached profile with another tenant's.
- uses: defdo_tenant_boundary@0.7.0 — `Defdo.Tenant.Boundary.Task.async/1` for any
  task my_mvno spawns during login (profile sync, `sync_oauth_app`); `Boundary.Oban`
  where a login enqueues.
- replaces: `Defdo.MyMvno.Authz.SessionActorResolver` (`lib/my_mvno/authz/session_actor_resolver.ex:15`,
  `:defdo_auth_user_info_resolver` env seam `:10`) → `Identity.from_session/1`;
  `Defdo.Hook.Actor` `{:with_actor, …}` / `{:require_actor, …}` (`lib/defdo/hook/actor.ex:32,51`)
  → `LiveHook` `:identity` / `{:require_identity, login_path:}` keeping the assigns key
  `:current_actor` (count readers: `grep -rln "current_actor" lib | wc -l`; record the
  number; if > 20 keep a one-line wrapper that assigns `identity.raw` under the old key,
  else update the readers); `lib/my_mvno_web/plug/cms_fetch_current_user.ex` → `Plug.Identity`.
  KEPT: `Defdo.MyMvno.Auth.Roles` (`roles.ex`: `@known_roles :16-28`, `def roles_from_user/1`
  `:74`, `def explicit_roles_from_user/1` `:64`), `Hook.Actor` `{:with_role, …}` (`:62`),
  `ScopeContext` for authorization. Decision file completed.
- gap: none.

## Goal

Tenant is established once per request by `Defdo.TenantPlug` and restored in LiveView by
its `on_mount`; the PKCE plug and `Site` run inside that context; the current actor is
`Identity`; `SessionActorResolver` is deleted. Both dev profiles sign in: Staff lands in
`/admin` with `current_role == "admin"`, Customer in the customer area with `"ciam"`.

## Preconditions

10a–10c merged.

## Targets

- `lib/my_mvno_web/router.ex` pipelines and `live_session` lists (`:281-284, :339, :358-359, :380, :412, :434, :466-469, :717-720`, re-locate).
- `lib/defdo/hook/actor.ex` (rewrite two clauses), `lib/my_mvno/authz/session_actor_resolver.ex` (delete),
  `lib/my_mvno_web/plug/cms_fetch_current_user.ex`, `lib/my_mvno/auth/tenant_resolver.ex`
  (delete or reduce to a custom `Defdo.TenantPlug` resolver), `.ai/decisions/2026-11-dev-idp-site.md`,
  `guides/runbooks/dev-login.md`, screenshots.

## Steps

1. Pipelines: `Defdo.TenantPlug.Plug` (options above) before `AuthorizeCodeWithPKCE`;
   `live_session … on_mount: [{Defdo.TenantPlug.LiveView, :default}, {Defdo.AuthClient.LiveHook, :identity}, …]`.
2. `Hook.Actor` clauses over `Identity`; `cms_fetch_current_user.ex` over `Plug.Identity`.
3. Delete `SessionActorResolver`; roles test (userinfo `roles: ["admin"]` → `preferred_role/1 == "admin"`;
   `["ciam"]` → `"ciam"`; if `explicit_roles_from_user/1` reads another key, extend the
   dev IdP payload in the PACKAGE, never a my_mvno hack).
4. Runbook + Look: `10-admin-staff-{light,dark,390}.png`, `10-customer.png`.

## Process map

Process map: no long-lived activity added or changed.

## Tests

- `tenant_edge_test.exs`: a request on a tenant host reaches the PKCE plug with
  `Defdo.Tenant.Context.tenant_id/0` set (guard: plug order) and the LiveView mount sees
  the same tenant (guard: `on_mount` order).
- `hook_actor_identity_test.exs`; roles test; `dev_idp_login_test.exs` through the router.
- Cross-tenant: two tenants' records in a fake consumer; a login on host A never resolves
  tenant B's client (guard: `Site.resolve(%{conn: conn})` reading context).

## Verification

```sh
! test -f lib/my_mvno/authz/session_actor_resolver.ex
grep -q 'Defdo.TenantPlug.Plug' lib/my_mvno_web/router.ex
grep -q 'Defdo.TenantPlug.LiveView' lib/my_mvno_web/router.ex
grep -q 'Defdo.AuthClient.LiveHook' lib/my_mvno_web/router.ex
grep -q 'def explicit_roles_from_user' lib/my_mvno/auth/roles.ex
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

## Acceptance criteria

- [ ] Tenant edge = `Defdo.TenantPlug` only; identity = `Identity` only; resolver deleted.
- [ ] Cross-tenant test green; roles unchanged; decision file complete with the reader count.
- [ ] Screenshots present.
