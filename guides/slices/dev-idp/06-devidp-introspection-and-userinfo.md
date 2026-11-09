---
kind: implementation
serves: [P-01, P-02]
skills: [defdo-platform, defdo-exunit-quality-tests, defdo-auth-ecosystem-patterns]
repo: defdo-dev/defdo_dev_idp
---

# Slice 06 — Introspection (both endpoints), userinfo, sign-out

Work only inside `defdo_dev_idp`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_auth_client@0.15 `Adapter.AuthCodePKCE.introspect/1` and `user_info/1`,
  `Defdo.AuthClient.CredentialIntrospection` — the request shapes to accept and the
  response shapes to answer (quoted in `00-conventions.md`).
- gap: none.

## Goal

The host's callback completes (`GET /openid/userinfo` answers `sub`), the gateway's
`AdminScope` admits the dev operator (`POST /api/v1/introspect` answers `active`,
`ai:admin` and `tenant.id == "dev-tenant"`), any host using `scope_in_token/2` works
(`POST /oauth/introspect`), and the index page's "Sign out everywhere" clears every dev
session so the next `/admin` shows the picker again (P-02).

## Preconditions

Slices 04, 05 merged.

## Targets

- `lib/defdo/dev_idp/web/router.ex`: `GET /openid/userinfo`, `POST /oauth/introspect`,
  `POST /api/v1/introspect`, `POST /session/clear`.
- `lib/defdo/dev_idp/web/introspect.ex` (new), `lib/defdo/dev_idp/web/userinfo.ex` (new).
- `lib/defdo/dev_idp/claims.ex` (new): the one function that builds the payload for a
  token, used by all three endpoints.

## Step 1 — Claims.for_token/2

```elixir
@spec for_token(Store.token_record(), Profile.t()) :: map()
def for_token(rec, profile) do
  %{"active" => true, "sub" => profile.sub, "username" => profile.email,
    "email" => profile.email, "name" => profile.name,
    "client_id" => rec.client_id, "token_type" => "Bearer",
    "exp" => rec.expires_at, "iat" => rec.issued_at,
    "scope" => Enum.join(rec.scope, " "), "scopes" => rec.scope,
    "tenant" => %{"id" => profile.tenant_id}, "tenant_id" => profile.tenant_id,
    "roles" => [profile.role]}
end
```

Both `scope` spellings and all three tenant spellings on purpose: gateway
`AdminScope.scope_list/1` and `tenant_id/1` accept either (verified gateway `main`,
2026-11-08), and the inactive answer is always exactly `%{"active" => false}`.

## Step 2 — POST /oauth/introspect (RFC 7662 shape the adapter calls)

Form body `token`, `client_id`, `client_secret` (also accept Basic). Client check as in
slice 02 Step 4; wrong → 401 `invalid_client`. Unknown/expired token →
`200 {"active": false}` (RFC 7662: never 4xx for an unknown token). Known →
`Claims.for_token/2`.

## Step 3 — POST /api/v1/introspect (what `SDK.introspect_credential/3` calls)

JSON body `{"token": "...", "token_type_hint": optional}`. Require header
`x-internal-token` equal to `config.internal_api_token` (`Plug.Crypto.secure_compare/2`)
else `401 {"error":"unauthorized"}`. Ignore any `x-internal-*` HMAC headers the client may
add (`internal_api_hmac: true` sends them; the dev IdP does not verify them — write that
in the moduledoc). Unknown token → `200 {"active": false}`; known → `Claims.for_token/2`.

## Step 4 — GET /openid/userinfo

`Authorization: Bearer <token>`. Unknown → `401 {"error":"invalid_token"}` with
`WWW-Authenticate: Bearer error="invalid_token"`. Known →

```json
{"sub":"dev-operator-dev-tenant","email":"operator@dev-tenant.dev.defdo","email_verified":true,
 "name":"Operator","preferred_username":"operator@dev-tenant.dev.defdo",
 "tenant_id":"<profile.tenant_id>","roles":["operator"],"scope":"openid profile ai:admin"}
```

The host callback only needs `sub` (`{:profile, %{"sub" => sub} = profile}` in
`plug/authorized_code_with_pkce.ex`, verified 0.14.0); the rest is for host
`:enrich_user` hooks and my_mvno's `Roles.roles_from_user/1`.

## Step 5 — POST /session/clear

`Store.clear_all_sessions/0`, expire the cookie, redirect `303` to `/`. The index page
then says "no dev session". Tokens are NOT revoked (the host still holds its own
session; the developer clears the host cookie or waits — document this on the page).

## Process map

Process map: no long-lived activity added or changed.

## Tests

- `/oauth/introspect`: active token → `active`, `scope` string, `scopes` list,
  `tenant.id`; unknown → `{"active": false}` with 200; wrong client → 401.
- `/api/v1/introspect`: missing header → 401 and body has no `sub` (guard: the header
  compare); right header → payload; `token_type_hint` ignored.
- `/openid/userinfo`: Bearer → `sub`; no header → 401 with `WWW-Authenticate`.
- Claims unit test: inactive shape is exactly `%{"active" => false}` (a map equality,
  not `assert payload["active"] == false`).
- `/session/clear` then `GET /oauth/authorize?...&prompt=none` → `login_required`
  (guard: `clear_all_sessions`).

## Verification

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
grep -q '"/api/v1/introspect"' lib/defdo/dev_idp/web/router.ex
grep -q '"/openid/userinfo"' lib/defdo/dev_idp/web/router.ex
grep -q 'x-internal-token' lib/defdo/dev_idp/web/introspect.ex
```

## Acceptance criteria

- [ ] All three endpoints answer the shapes in Steps 2–4; tests exist by name.
- [ ] Inactive answer is exactly `%{"active" => false}` on both introspection endpoints.
- [ ] `x-internal-token` mismatch is 401; HMAC headers do not break the call.
- [ ] Sign-out makes the next `prompt=none` authorize answer `login_required`.
