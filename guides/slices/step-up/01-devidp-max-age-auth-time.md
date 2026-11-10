---
kind: implementation
serves: []
skills: [defdo-platform, defdo-sso-flow-test, defdo-exunit-quality-tests, defdo-property-tests]
repo: defdo-dev/defdo_dev_idp
---

`serves: []` in this repo — the scenario is core_back_office P-17 (see `README.md`).

# Slice 01 — The dev IdP re-asks on `prompt=login` / `max_age` and says when you signed in

Work only inside `defdo_dev_idp`. Read `../dev-idp/00-conventions.md`.

## Ecosystem

- uses: this package's own `Store`, `Web.Authorize`, `Web.Token`, `Claims`, `Web.Discovery`
- uses: defdo_auth_client (test only) — after its step-up release, the integration test of dev-idp slice 08 can drive the real plug with `max_age`; until then this slice is proven with direct HTTP requests

## Goal

The dev IdP behaves like an OpenID provider for re-authentication:

- every id_token says when the profile was chosen (`auth_time`);
- `prompt=login` shows the picker even when a dev session exists;
- `max_age` shows the picker when the dev session is older than that many seconds; `max_age=0` always does;
- `prompt=none` together with a request that needs the picker answers `login_required`.

A host can then prove a step-up sign-in locally, with no real identity provider.

## Preconditions

- dev-idp slices 05 (authorize, token) and 06 (introspection, userinfo) merged. Branch from `main` after them.
- Read `../dev-idp/00-conventions.md`.

## Targets

Verified at branch `slice/dev-login-08-gate-and-client-proof` (`6edb8fa`) — re-locate with grep before editing.

- `lib/defdo/dev_idp/store.ex` — `put_session/2` (stores `{sid, profile_key}`), `get_session/1`
- `lib/defdo/dev_idp/web/authorize.ex` — `@type request`, `validate/2`, `respond_get/3` (the `cond` that picks headless / session / `prompt=none` / picker), `post/1`, `issue/3` (the code record), `session_profile/2`
- `lib/defdo/dev_idp/web/pages.ex` — the picker's hidden inputs (it carries the request back in the POST)
- `lib/defdo/dev_idp/keys.ex` — `picker_token/1` (HMAC over `state`, `client_id`, `redirect_uri`)
- `lib/defdo/dev_idp/web/token.ex` — `claims/4` (the id_token claims)
- `lib/defdo/dev_idp/claims.ex` — `userinfo/2`, `for_token/2`
- `lib/defdo/dev_idp/web/discovery.ex`
- `test/defdo/dev_idp/web/authorize_token_test.exs`, `test/support/flow.ex`, `test/defdo/dev_idp/web/router_test.exs`
- `README.md`, `CHANGELOG.md`

## Step 1 — The dev session remembers when it began

`Store.put_session(sid, profile_key)` becomes `put_session(sid, profile_key, authenticated_at)`
and stores `{sid, profile_key, authenticated_at}` (Unix seconds). `get_session/1` returns
`{:ok, profile_key, authenticated_at}`. `Web.Authorize.session_profile/2` returns
`{profile, authenticated_at}` or `nil`; its one other caller (the index page's "signed in
as") takes the profile from the tuple.

There is exactly one moment a person authenticates here: when they pick a profile
(`post/1`), or when a request names one with the headless `profile=` parameter. Both use
`Store.now()` as `authenticated_at`. Reusing a session never changes it.

## Step 2 — The request carries `max_age`

Add to `@type request` and `validate/2`:

```elixir
max_age: non_neg_integer() | nil
```

Parsing: absent → `nil`. A string of ASCII digits, at most 9 → that integer. Anything else
→ `{:error, "invalid_request", "max_age must be a non-negative integer"}`, shown on the
dev IdP's own error page like the other request errors (never redirected). `prompt` stays
a string; values other than `none` and `login` behave as absent.

The picker form must carry `prompt` and `max_age` back in its hidden inputs
(`Pages.picker`), because `post/1` validates the request again from the POST. They are NOT
part of the picker token's HMAC; tampering with them only makes the IdP ask more or less
often, which the person at the picker controls anyway.

## Step 3 — When the picker is shown

Replace the `cond` in `respond_get/3` with this decision, in this order:

| # | Condition | Result |
|---|---|---|
| 1 | the request names `profile=` (headless) | issue for that profile, `auth_time` = now |
| 2 | a live dev session exists AND the request does not force a re-login | issue for the session's profile, `auth_time` = the session's `authenticated_at` |
| 3 | `prompt=none` | redirect to `redirect_uri` with `error=login_required` and `state` |
| 4 | otherwise | the picker |

"Forces a re-login" is true when `prompt == "login"`, OR `max_age` is an integer and
`now - authenticated_at > max_age` (so `max_age=0` forces it for any session older than the
current second — treat `max_age == 0` as always forcing, without comparing clocks).

Row 3 therefore also covers `prompt=none` with a session that is too old for `max_age`:
`login_required`, never a silent pass.

`post/1` (a profile was chosen at the picker) always creates a NEW session id with
`authenticated_at = now`, replacing the cookie. It never loops: the POST issues the code
directly and does not go back through `respond_get/3`.

Write the function so credo's limits hold: no `cond` with a single branch plus `true`,
complexity ≤ 9. A small `needs_login?(request, authenticated_at, now)` keeps it flat.

## Step 4 — `auth_time` travels to the id_token

- `issue/3` takes the `auth_time` and stores it in the code record next to `nonce`.
- `Web.Token.claims/4` adds `"auth_time" => stored.auth_time` to EVERY id_token (an integer, Unix seconds), whether or not `max_age` was sent.
- Userinfo and introspection do not gain `auth_time`: the real provider's contract puts it in the id_token, and the client must not learn to read it from userinfo.
- `Web.Discovery`: add `"claims_supported"` listing the id_token claims this IdP emits, `auth_time` among them, ONLY if the real defdo_auth's discovery document has that key after its own slice (PR-2). If it does not, do not add it: the dev IdP's discovery stays at the keys dev-idp slice 04 fixed. State which case applied in the PR.

A `client_credentials` token has no person and no id_token; nothing changes there.

## Step 5 — A way to test an old sign-in

Tests of a host need a session that is too old. Add a start-only option, read like
`:site_reader` (a start option, never application config):

```elixir
{Defdo.DevIdp, [..., clock: fn -> System.system_time(:second) end]}
```

`Store.now/0` calls the configured clock. A test starts the server with a clock it can
move. There is no HTTP parameter that back-dates `auth_time`: a request must never be able
to choose the time it claims.

## Step 6 — Docs

`README.md`: a "Re-authentication" section with the table of Step 3 and one sentence on
`auth_time`. `CHANGELOG.md` under the unreleased version.

## Process map

Process map: no long-lived activity added or changed (the `Store` process keeps one more field per session row).

## Tests

In `authorize_token_test.exs`, a `describe "re-authentication"`:

- "every id_token carries an integer auth_time" — headless flow; `auth_time` is within 2 s of now.
- "a reused session keeps the auth_time of when the profile was chosen" — choose at T, move the clock +100 s, authorize again without `prompt`; `auth_time == T`.
- "prompt=login shows the picker even with a live session" — status 200 and the picker body, not a redirect.
- "after choosing again, auth_time is the new time and the session id changed".
- "max_age=0 shows the picker with a live session".
- "max_age=300 reuses a session 300 s old and shows the picker for one 301 s old" (the boundary, with the test clock).
- "prompt=none with a session too old for max_age answers login_required".
- "prompt=none with a fresh enough session issues a code".
- "a malformed max_age is an invalid_request on the IdP's own page" — `-1`, `abc`, `1.5`, ten digits; nothing is redirected to the client.
- "the picker form carries prompt and max_age back" — submit the picker's hidden fields; the code is issued.
- "userinfo and introspection do not carry auth_time".
- property (stream_data): "for any session age and any max_age, the picker is shown exactly when prompt is login, or max_age is 0, or age > max_age" — against `needs_login?/3`.

In `router_test.exs`: the discovery test is unchanged, or gains `claims_supported` (Step 4).

Guard-removal checks to run and report: make row 2 ignore `prompt=login`; make a reused
session take `auth_time` = now; drop `max_age` from the picker's hidden inputs. Each must
turn a named test red.

## Verification

```sh
grep -q '"auth_time"' lib/defdo/dev_idp/web/token.ex
grep -q 'max_age' lib/defdo/dev_idp/web/authorize.ex
grep -q 'max_age' lib/defdo/dev_idp/web/pages.ex
sh -c '! grep -n "auth_time" lib/defdo/dev_idp/claims.ex'
sh -c '! grep -rn "Application.get_env(:defdo_dev_idp, :clock" lib'
grep -q 'Re-authentication' README.md
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

## Acceptance criteria

- [ ] Every id_token has an integer `auth_time`; a reused session reports the original time (named test green; guard removal turned it red).
- [ ] `prompt=login` and `max_age=0` show the picker with a live session; the 300/301 s boundary test is green.
- [ ] `prompt=none` never passes silently when a re-login is needed.
- [ ] A malformed `max_age` is refused on the IdP's page, not redirected.
- [ ] No request parameter can set `auth_time`; the clock is a start option only.
- [ ] Userinfo and introspection are unchanged.
- [ ] The PR states whether `claims_supported` was added and why.
- [ ] Full verification block green; nothing tagged.
