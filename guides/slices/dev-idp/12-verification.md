---
kind: implementation
serves: [P-04, P-05]
skills: [defdo-platform, defdo-woodpecker-pipeline, defdo-exunit-quality-tests]
repo: defdo-dev/defdo_dev_idp (and each host after its slice)
---

# Slice 12 — The durable gate

## Goal

Five regressions can never ship silently: (1) dev IdP drift from the client wire contract,
(2) a host prod artifact carrying the package, (3) a dev host pointed at a remote IdP
without the package, (4) a host re-growing a private auth seam, (5) a config file carrying
a site/id/secret instead of a vault project.

## Preconditions

Slice 08 (package) and each host slice as it lands.

## Gate 1 — Contract drift (package)

`test/integration/pkce_login_test.exs` on every CI run; `.woodpecker/contract.yml`
(`labels: platform: linux/amd64`, `when: event: cron`) runs
`mix deps.update defdo_auth_client && mix test test/integration` weekly; alerts, never commits.

## Gate 2 — Prod artifact (each host)

`assert-no-dev-idp.sh deps` where mix exists; `assert-no-dev-idp.sh release <dir>` on the
release tree before it is copied into the runtime image. Named checks; missing dir and
failed mix are red (slice 08).

## Gate 3 — Dev boot honesty (package fixture, real absence)

`test/fixtures/host_without_dev_idp/` is a minimal Mix project (committed, `mix.lock`
committed, deps `defdo_auth_client` only — the fixture's deps are vendored under `deps/`
by the author so the driver fetches nothing) whose test sets
`config :defdo_auth_client, :env, :dev`, puts an app record with `site: "https://auth.example.test"`
in env and asserts `Defdo.AuthClient.DevGuard.check!/1` raises `DevSiteError`. The package
CI runs `cd test/fixtures/host_without_dev_idp && mix test`. `Code.ensure_loaded?(Defdo.DevIdp)`
is false there for REAL (the dep is absent), so no module stubbing.

Each host adds `test/<host>/dev_guard_test.exs` asserting the positive case: with the
dep present, the same remote site does NOT raise (the guard's `dev_idp_loaded?` branch).

## Gate 4 — No private seams (each host) with an exemption control

```elixir
@forbidden ~r/Config\.from_env\(\[:client|VaultClientSecret|current_user_adapter|SessionActorResolver|studio_authenticator|_defdo_auth_me|admin-oauth-site/
@exempt ["lib/my_mvno/release.ex"]           # the legacy-record migration task, one per host, named here

test "auth seams come only from defdo_auth_client" do
  assert File.dir?("lib")
  files = Path.wildcard("lib/**/*.ex")
  assert length(files) > 20
  hits = files |> Enum.reject(&(&1 in @exempt)) |> Enum.filter(&(File.read!(&1) =~ @forbidden))
  assert hits == [], "private auth seams re-introduced: #{inspect(hits)}"
end

test "the exemption carries the forbidden needle (control)" do
  # the migration module MUST still contain a legacy code name, otherwise the exemption is decoration
  assert Enum.all?(@exempt, &(File.read!(&1) =~ @forbidden))
end
```

A host that keeps a term on purpose (theme_hub `Api.Auth.mode`) does not list that term.
Delete the exemption and the control test goes red — that is the proof it tests something.

## Gate 5 — Config names codes only (each host)

```elixir
test "config files carry no site, id or secret for the auth client" do
  files = Path.wildcard("config/*.exs")
  assert length(files) >= 3
  bad = Enum.filter(files, &(File.read!(&1) =~ ~r/Defdo\.AuthClient,\s*\n?\s*(site:\s*\[[^\]]*\b(site|client_id|client_secret|tenant|connection):|client:\s*\[)/s))
  assert bad == [], "auth client values in config: #{inspect(bad)} — only `site: [vault_project: ...]` is allowed"
end
```

Control: a temp copy of `config/dev.exs` with `site: [site: "https://x"]` appended makes the
regex match (unit test over the regex with the two shapes: `vault_project:` passes,
`site:`/`client_id:`/`client:` fail).

## Verification (package)

```sh
test -f .woodpecker/contract.yml
grep -q "event: cron" .woodpecker/contract.yml
grep -q "platform: linux/amd64" .woodpecker/contract.yml
test -f test/fixtures/host_without_dev_idp/mix.exs
test -f test/fixtures/host_without_dev_idp/mix.lock
test "$(grep -c 'assert-no-dev-idp\[' scripts/ci/assert-no-dev-idp.sh)" -ge 5
mix test test/integration
```

## Acceptance criteria

- [ ] Contract cron; fixture project runs in CI and is red when the guard is removed.
- [ ] Each host: both gate lines, the positive dev-guard test, Gate 4 with its control,
      Gate 5 with its regex control — by file name.
- [ ] Review of each host slice checks `Ecosystem` lines against the diff: a host that adds
      a resolver, adapter, authenticator or config-file site is a P1 finding.
