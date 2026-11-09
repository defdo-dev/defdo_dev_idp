---
kind: implementation
serves: [P-04, P-01]
skills: [defdo-platform, defdo-sso-flow-test, defdo-exunit-quality-tests, defdo-woodpecker-pipeline]
repo: defdo-dev/defdo_dev_idp
---

# Slice 08 — Prod gate (fail-closed, no mix at runtime) + proof against the real plug

Work only inside `defdo_dev_idp`. Read `00-conventions.md`.

## Ecosystem

- uses: defdo_auth_client@0.15 — `Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE` resolving
  through `Site` (slice 02), `Defdo.AuthClient.Identity.from_session/1` (slice 03),
  `Defdo.AuthClient.SDK.introspect_credential/3`. The dev IdP is proven by the client.
- uses: plug `Plug.Test`, `Plug.Session`; bandit for the fake host.
- gap: none.

## Goal

1. `scripts/ci/assert-no-dev-idp.sh` has two modes and fails closed:
   `assert-no-dev-idp.sh release <dir>` checks the release tree only (no mix: runtime
   images and release dirs have none — gateway and my_mvno Dockerfiles copy
   `_build/prod/rel/<app>` into a runtime stage without Elixir); `assert-no-dev-idp.sh deps`
   runs `mix deps.tree --only prod` where mix exists (release-validate / build stage) and
   treats a FAILED mix command as a failure, not as "no match".
2. `Defdo.DevIdp.Gate.assert_absent!/1` = the `release` mode from ExUnit.
3. An integration test logs a fake host in through the real plug and reads the identity
   with the real `Identity`; then the SDK introspects the token the gateway way.

## Preconditions

Slices 04–06 merged.

## Targets

- `scripts/ci/assert-no-dev-idp.sh` (new, executable, POSIX sh), `lib/defdo/dev_idp/gate.ex`,
  `test/integration/pkce_login_test.exs`, `test/support/fake_host.ex`, `test/scripts/gate_script_test.exs`.
- `.woodpecker/ci.yml`: steps `gate-script-self-check` (below).

## Step 1 — The script (four checks, each names itself)

```sh
#!/bin/sh
# usage: assert-no-dev-idp.sh release <release-dir>   (no mix needed; run on the release tree or inside the image)
#        assert-no-dev-idp.sh deps                    (needs mix; run where MIX_ENV=prod deps are fetched)
set -eu
mode="${1:?mode: release|deps}"
case "$mode" in
  release)
    dir="${2:?release dir}"
    [ -d "$dir/lib" ] || { echo "assert-no-dev-idp[release-dir]: not found: $dir" >&2; exit 1; }
    if find "$dir/lib" -name 'Elixir.Defdo.DevIdp*.beam' | grep -q .; then
      echo "assert-no-dev-idp[beams]: Defdo.DevIdp beams present in $dir" >&2; exit 1; fi
    if find "$dir/lib" -maxdepth 1 -name 'defdo_dev_idp-*' | grep -q .; then
      echo "assert-no-dev-idp[app-dir]: defdo_dev_idp application present in $dir/lib" >&2; exit 1; fi
    echo "assert-no-dev-idp: ok (release $dir)";;
  deps)
    if ! out=$(MIX_ENV=prod mix deps.tree --only prod 2>&1); then
      echo "assert-no-dev-idp[deps-tree]: mix deps.tree failed:" >&2; printf '%s\n' "$out" >&2; exit 1; fi
    if printf '%s\n' "$out" | grep -q 'defdo_dev_idp'; then
      echo "assert-no-dev-idp[deps-tree]: defdo_dev_idp is in the prod dependency tree" >&2; exit 1; fi
    echo "assert-no-dev-idp: ok (deps)";;
  *) echo "assert-no-dev-idp[usage]: unknown mode $mode" >&2; exit 2;;
esac
```

Round 1: the old script `2>/dev/null`-ed `mix deps.tree` under `set -eu` without
`pipefail`, so a missing mix made the pipeline green. Now the command's status is
captured and a failure is a failure. Four checks: `release-dir`, `beams`, `app-dir`,
`deps-tree`.

## Step 2 — Gate.assert_absent!/1

The `release` mode in Elixir: raises `RuntimeError` with the same bracketed check names.

## Step 3 — FakeHost

`Plug.Router` + `Plug.Session` (cookie store, fixed `secret_key_base`) + `fetch_session`;
`GET /oauth2/defdo_auth` → `Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE` with
`scopes: ~w(openid profile ai:admin), state_store: :session` and NO `resolve_client` —
the client comes from the `Site` APP RECORD put in env by the test (the Runtime's output
shape: `site: [vault_project: "test", site: <dev idp>, tenant: …, connection: "dev-connection", client_id: "dev-gateway", client_secret: "dev-gateway-secret", redirect_uri: <fake host>/oauth2/defdo_auth, scopes: "openid profile ai:admin"]`)
(the dev IdP base is known only after `start_supervised!` on port 0, so the test sets
the env in `setup_all` and restores it). `GET /whoami` → `Identity.from_conn(conn)` as
JSON. Verify option names against the locked source first
(`grep -n ":state_store\|:scopes" deps/defdo_auth_client/lib/defdo/defdo_auth/plug/authorized_code_with_pkce.ex`).

## Step 4 — The login test

With a minimal cookie-jar helper over `Req` (collect `set-cookie`, resend):

1. `GET fake/oauth2/defdo_auth` → 302 to `/oauth/authorize?...` with `code_challenge_method=S256`, `state`, `scope`.
2. `GET` it → 200 picker; parse hidden fields incl. `picker_token`; `POST` operator.
3. 302 to `fake/oauth2/defdo_auth?code=…&state=…`; `GET` it with the fake host cookie.
4. `GET fake/whoami` → `sub == "dev-operator-dev-tenant"`, `tenant_id == profile.tenant_id`,
   `roles == ["operator"]`, `"ai:admin" in scopes`.
5. `Defdo.AuthClient.SDK.introspect_credential(access_token, %{})` with
   `introspection: [internal_api_token: "dev-internal-token"]` configured (slice 02
   default path) → `{:ok, %{"active" => true, "tenant" => %{"id" => tenant_id}}}`.
6. Negative: after `POST /session/clear`, a login with `prompt=none` yields the plug's
   interactive retry (second 302 without `prompt`).

## Step 5 — Script self-check in CI

`.woodpecker/ci.yml` steps (`labels: platform: linux/amd64`):

- `MIX_ENV=prod mix release --overwrite` then `! sh scripts/ci/assert-no-dev-idp.sh release _build/prod/rel/defdo_dev_idp`
  must FAIL with `[beams]` (this package's own release contains itself — the gate must
  be red on it): `sh scripts/ci/assert-no-dev-idp.sh release _build/prod/rel/defdo_dev_idp 2>&1 | grep -q '\[beams\]'`.
- `sh scripts/ci/assert-no-dev-idp.sh release /nonexistent 2>&1 | grep -q '\[release-dir\]'`.
- `PATH=/usr/bin:/bin sh scripts/ci/assert-no-dev-idp.sh deps 2>&1 | grep -q '\[deps-tree\]: mix deps.tree failed'`
  (mix absent from PATH → must fail closed).

## Process map

Process map: no long-lived activity added or changed (test-only processes).

## Tests

- Step 4.
- `gate_test.exs`: temp dir with `lib/defdo_dev_idp-0.1.0/ebin/Elixir.Defdo.DevIdp.beam`
  → raise with `[beams]`; only `lib/other-1.0/` → ok; missing dir → `[release-dir]`.
- `gate_script_test.exs` (`System.cmd("sh", [...])`): the same three for the script, plus
  `deps` with `PATH` lacking mix → exit 1 and stderr contains `mix deps.tree failed`
  (guard: the `if ! out=$(…)`).

## Verification

```sh
grep -q '"defdo_auth_client"' mix.lock
test -x scripts/ci/assert-no-dev-idp.sh
test "$(grep -c 'assert-no-dev-idp\[' scripts/ci/assert-no-dev-idp.sh)" -ge 5
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
sh scripts/ci/assert-no-dev-idp.sh release /nonexistent 2>&1 | grep -q 'release-dir'
PATH=/usr/bin:/bin sh scripts/ci/assert-no-dev-idp.sh deps 2>&1 | grep -q 'mix deps.tree failed'
```

## Acceptance criteria

- [ ] Integration test logs in through the REAL plug with no `resolve_client`, reads the
      identity through the REAL `Identity`; only the picker POST is hand-built.
- [ ] Script: two modes, four named checks, mix failure is red (test + CI step).
- [ ] CI runs the gate on the package's own prod release and expects `[beams]`.
- [ ] CHANGELOG `## 0.1.0` lists slices 04–08; owner tags after 07 AND 08 are merged.
