---
kind: implementation
serves: [P-01, P-02, P-03, P-06]
skills: [defdo-platform, defdo-property-tests, defdo-exunit-quality-tests, defdo-sso-flow-test]
repo: defdo-dev/defdo_dev_idp
---

# Slice 05 — Authorize picker, PKCE codes, token endpoint, id_token + JWKS

Work only inside `defdo_dev_idp`. Read `00-conventions.md` (the "client contract"
table is the spec of this slice).

## Ecosystem

- uses: jose ~> 1.11 — `JOSE.JWK.generate_key({:rsa, 2048})`, `JOSE.JWT.sign/3`,
  `JOSE.JWK.to_public_map/1` (verify names with `grep -rn "def generate_key\|def to_public_map\|def sign" deps/jose/lib/jose/jwk.ex deps/jose/lib/jose/jwt.ex`).
- uses: defdo_auth_client@0.15 `Defdo.DefdoAuth.Strategy.AuthCodePKCE` — the
  parameters this endpoint must accept (quoted in `00-conventions.md`).
- gap: none.

## Goal

A browser sent by the host's PKCE plug to `/oauth/authorize` sees the profile picker,
picks one, is redirected back with a code; the plug exchanges it at `/oauth/token` with
its `code_verifier` and gets an access token, `expires_in`, `scope` and a signed
`id_token` whose key `/.well-known/jwks.json` publishes. `prompt=none` without a dev
session answers `error=login_required`. A `redirect_uri` outside `localhost` is refused.

## Preconditions

Slice 04 merged. Read `00-conventions.md`.

## Targets

- `lib/defdo/dev_idp/store.ex` (replace the stub): ETS-backed GenServer, tables
  `codes`, `tokens`, `sessions`.
- `lib/defdo/dev_idp/keys.ex` (new): one RSA key generated in `init/1`, `kid` = 8 hex
  chars of its thumbprint, `jwks/0`, `sign_id_token/2`.
- `lib/defdo/dev_idp/web/router.ex`: routes `GET /oauth/authorize`, `GET /openid/authorize` (legacy alias, same handler — see conventions),
  `POST /oauth/authorize`, `POST /oauth/token`, `GET /.well-known/jwks.json`.
- `lib/defdo/dev_idp/web/authorize.ex`, `lib/defdo/dev_idp/web/token.ex`,
  `lib/defdo/dev_idp/web/pages.ex` (add `picker/3`).
- `lib/defdo/dev_idp/pkce.ex` (new).

## Step 1 — Store

```elixir
Store.put_code(code, %{profile_key, client_id, redirect_uri, code_challenge, scope, nonce, expires_at})
Store.take_code(code)        # {:ok, map} | :error — single use, deletes on read, nil if expired
Store.put_token(token, %{profile_key, client_id, scope, expires_at})
Store.get_token(token)       # {:ok, map} | :error (expired → :error and deleted)
Store.put_session(sid, profile_key) / get_session(sid) / clear_all_sessions()
```

Codes live 60 s, tokens 3600 s. Values are 32 random bytes, `Base.url_encode64(padding: false)`.

## Step 2 — PKCE

```elixir
defmodule Defdo.DevIdp.PKCE do
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier), do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  @spec verify(verifier :: String.t(), challenge :: String.t()) :: boolean()
  def verify(verifier, challenge), do: Plug.Crypto.secure_compare(challenge(verifier), challenge)
end
```

This is byte-for-byte what `Defdo.DefdoAuth.Strategy.AuthCodePKCE` computes
(`strategy/auth_code_pkce.ex:71`, verified 0.14.0, unchanged by slices 01–03). Only `S256` is accepted; `plain` or
a missing method → `error=invalid_request`.

## Step 3 — GET /oauth/authorize

Validate, in this order, answering a JSON 400 `{"error": "...", "error_description": "..."}`
for the first failure (these are client bugs, not user errors):

1. `client_id == config.client.id` else `invalid_client`.
2. `response_type == "code"` else `unsupported_response_type`.
3. `redirect_uri` parses, scheme `http`, host in `["localhost", "127.0.0.1"]` else
   `invalid_request` (P-06 — never redirect to the offending URI).
4. `code_challenge` present and `code_challenge_method == "S256"` else `invalid_request`.
5. `state` present else `invalid_request` (the client always sends one:
   `maybe_state/2` in the strategy).

Then:

- If `profile` param names a configured profile key → issue the code and redirect
  (headless path, P-03).
- Else if the request carries the dev session cookie `_defdo_dev_idp` with a live
  session → issue for that profile (this is what makes `prompt=none` work after the
  first login).
- Else if `prompt == "none"` → `302 redirect_uri?error=login_required&state=<state>`.
- Else render `Pages.picker(config, params, signed_in)`: one card per profile with a
  form `POST /oauth/authorize` carrying all validated params as hidden fields plus
  `profile=<key>`, a `Continue` button, `<h1>` with the host name, and a line "Dev IdP —
  not a real login". HTML-escape every value.

`POST /oauth/authorize` re-validates exactly like GET (same function), requires
`profile`, issues the code, sets the session cookie (`HttpOnly`, `SameSite=Lax`, path
`/`, 8 h) and redirects `302` to `redirect_uri?code=<code>&state=<state>`.

Issuing a code = `Store.put_code/2` with `scope` = the request's `scope` param
intersected with the profile's scopes (a profile without `ai:admin` never gets it even
if asked; order preserved), `nonce` from params if present.

## Step 4 — POST /oauth/token

Accept `application/x-www-form-urlencoded`. Client authentication, either:

- body `client_id` + `client_secret`, or
- `Authorization: Basic base64(id:secret)`.

(The dev client always has a secret — `Config` requires it — so there is no public-client
branch. Round 1 removed it as dead code.)

Wrong credentials → `401 {"error":"invalid_client"}`. Then require
`grant_type == "authorization_code"`, `code`, `redirect_uri`, `code_verifier`:

1. `Store.take_code(code)` → `:error` → `400 invalid_grant`.
2. `redirect_uri` equals the stored one → else `invalid_grant`.
3. `PKCE.verify(code_verifier, stored.code_challenge)` → else `invalid_grant`.

Success → `Store.put_token/2` and `200`:

```json
{"access_token":"<token>","token_type":"Bearer","expires_in":3600,
 "scope":"openid profile ai:admin","id_token":"<jwt>"}
```

`id_token` claims: `iss` = base URL, `sub`, `aud` = client id, `exp`, `iat`, `nonce`
(when stored), `email`, `name`, `tenant_id` = `profile.tenant_id`, `roles: [role]`. Signed RS256 with the
slice's key, header `kid`.

## Step 5 — JWKS

`GET /.well-known/jwks.json` → `{"keys":[<public JWK with kid, use: "sig", alg: "RS256">]}`.

## Process map

| Activity | Where it hangs | Starts after | Stopping it stops | Owns | Alive? |
|---|---|---|---|---|---|
| `Defdo.DevIdp.Store` (GenServer + 3 ETS tables) | `Defdo.DevIdp` supervisor | `Boot.ensure!` | every in-flight login (codes) and session | codes, tokens, sessions | `:ets.whereis(:defdo_dev_idp_codes)` |
| `Defdo.DevIdp.Keys` (GenServer, one RSA key) | `Defdo.DevIdp` supervisor | same | id_token signing; JWKS answers 503 | the key pair | `Process.whereis/1` |

Update `guides/PROCESS_MAP.md`.

## Tests

HTTP tests through `Req` against the started server (ephemeral port):

- authorize happy path with `profile=operator` → 302, `Location` has `code` and the same
  `state`; token exchange with the matching verifier → 200 with the five keys;
  `expires_in == 3600`; id_token verifies against JWKS (`JOSE.JWT.verify_strict/3`) and
  has `sub == "dev-operator-dev-tenant"`.
- wrong verifier → 400 `invalid_grant` (guard: `PKCE.verify`).
- code used twice → second 400 `invalid_grant` (guard: `take_code` delete).
- `redirect_uri=http://evil.test/cb` → 400 `invalid_request` and NO `Location` header
  (guard: host allowlist).
- `prompt=none` without cookie → 302 `error=login_required&state=…`.
- picker GET renders one `<form>` per profile; label `<b>x</b>` escaped.
- scope narrowing: profile `customer` asked for `ai:admin` gets `"openid profile"`.
- Basic client auth accepted; wrong secret → 401 `invalid_client`.
- picker POST without `picker_token`, or with a token signed for another `state`, → 400
  `invalid_request` and no code issued (guard: the token check).
- Properties (`stream_data`): `PKCE.verify(v, PKCE.challenge(v))` for any 43..128-char
  unreserved verifier; and for any other verifier `v2 != v`, false. Store: putting N
  distinct codes and taking each once yields each exactly once (stateful model with
  `put`/`take`/`expire` commands).

## Verification

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
grep -q "login_required" lib/defdo/dev_idp/web/authorize.ex
grep -q "S256" lib/defdo/dev_idp/pkce.ex
grep -q "picker_token" lib/defdo/dev_idp/web/authorize.ex
grep -q "Store" guides/PROCESS_MAP.md
```

## Acceptance criteria

- [ ] All tests above exist by name and are green.
- [ ] Deleting the `PKCE.verify` call makes the wrong-verifier test red (checked once by
      the implementer, noted in the PR).
- [ ] No token or code string appears in any `Logger` call (`grep -n "Logger" lib | grep -i "code\|token"` is empty).
- [ ] A `redirect_uri` outside localhost never produces a redirect.
- [ ] JWKS verifies the id_token.
