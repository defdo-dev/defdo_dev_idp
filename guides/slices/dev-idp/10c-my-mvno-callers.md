---
kind: implementation
serves: [P-01, P-05]
skills: [defdo-platform, defdo-auth-ecosystem-patterns, defdo-tenant-edge-contract, defdo-scoped-refactor-assistant]
repo: defdo-dev/defdo_my_mvno
---

# Slice 10c — my_mvno: move every `VaultSecret` caller to `Site`; delete the old readers

Work only inside `defdo_my_mvno`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_auth_client@0.15 `Site.resolve/1`, `Site.put/2`, `Site.Client.to_service_oauth_opts/1`.
- replaces: `Defdo.OAuth.VaultSecret`, `Defdo.OAuth.VaultClientSecret`,
  `Defdo.MyMvno.Authz.SessionActorResolver` (deleted in 10d after `Identity` lands),
  `lib/my_mvno_web/plug/defdo_auth_client_config.ex` (the per-request `put_config` of the
  old record — the library plug resolves through `Site` now).
- gap: none expected; any need that `Site` cannot answer is a contract slice first.

## Goal

No module in my_mvno reads or writes an OAuth client record except through `Site`.

## Preconditions

10a, 10b merged (records exist; plug no longer needs `VaultSecret`).

## Targets (the callers, `git grep -l VaultSecret origin/main -- lib`, verified 2026-11-08)

| File | Today | After |
|---|---|---|
| `lib/my_mvno/first_run.ex` | writes the instance `defdo_auth` record | `Site.put(%{vault_tenant_id: instance_tenant}, content)` |
| `lib/my_mvno/auth/service_client.ex` | reads the service (M2M) record | `Site.resolve(%{}) \|> Client.to_service_oauth_opts/1` |
| `lib/my_mvno/auth/management_auth.ex` | reads client config for management API | `Site.resolve(ctx)` |
| `lib/my_mvno/auth/tenant_resolver.ex` | resolves tenant from the record / host | keep the HOST→tenant part (that is `Defdo.TenantPlug`'s job, 10d); drop record reads |
| `lib/my_mvno/auth/oauth_login_config.ex`, `oauth_scope_catalog.ex` | scopes / types | read `client.scopes`, `registration_type`, `connection_type` |
| `lib/my_mvno/authz/scope_context.ex` | `oauth_config(tenant_id)` | `Site.resolve(%{tenant_id: id})` — called only at edges that already hold context; prefer `Site.resolve(%{})` inside context |
| `lib/my_mvno/cms/oauth_client_adapter.ex` | cms adapter over `VaultSecret` | `Site` (cms itself migrates in slice 11) |
| `lib/my_mvno/commerce/fulfillment_routes.ex`, `lib/my_mvno/connections.ex`, `lib/my_mvno/domains/host.ex`, `lib/my_mvno/domains/vault_secrets.ex`, `lib/my_mvno/payments.ex`, `lib/my_mvno/vault_access.ex` | mixed: some read the OAuth record, some use `VaultSecret` as a generic vault helper | split: OAuth-record reads → `Site`; generic vault helpers → `Defdo.Vault.Consumer` directly (no OAuth shape) |
| `lib/my_mvno/instance_tenant.ex` | instance tenant + record | reduce to the registry edge (tenant lookup); record via `Site` |
| `lib/my_mvno/security/admin_sudo.ex` | re-auth client | `Site.resolve(ctx)` |
| `lib/my_mvno_web/live/admin/vault/secret_live/form.ex` | edits the record in the vault UI | edits through `Site.put/2`; the form renders the contract keys |
| `lib/my_mvno_web/live/admin/...idp_credentials_live.ex` (review-listed; re-locate) | shows/edits IdP credentials | `Site.resolve/1` + `Site.put/2`; secrets shown as first4••••last4 only (`credential-hints-last4`) |
| `lib/my_mvno_web/plug/defdo_auth_client_config.ex` | `put_config` per request | delete |
| `lib/defdo/oauth/vault_secret.ex`, `vault_client_secret.ex` | the old reader | delete |

Also remove the `:defdo_auth_login_scopes` env knob (`config/dev.exs:106-107`): scopes come
from the record.

## Steps

1. Move callers one file at a time in the table order; compile after each.
2. Delete `plug/defdo_auth_client_config.ex`, then `vault_secret.ex`/`vault_client_secret.ex`.
3. Decision file: the table above with what each caller kept (host logic) and dropped.

## Tests

- Each moved module keeps its tests green with the record provided as `Site` env/fake
  consumer; `service_client_test.exs` mints via `to_service_oauth_opts/1` against the dev
  IdP's `client_credentials`.
- `! grep -rn "VaultSecret" lib/` is part of Verification.

## Verification

```sh
! grep -rn 'VaultSecret\|VaultClientSecret' lib/
! test -f lib/my_mvno_web/plug/defdo_auth_client_config.ex
! grep -n 'defdo_auth_login_scopes' config/dev.exs
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

## Acceptance criteria

- [ ] Zero `VaultSecret` references; old modules deleted; env knob gone.
- [ ] Decision table complete (every file in Targets has a row with kept/dropped).
