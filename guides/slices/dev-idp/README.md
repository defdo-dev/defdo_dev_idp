# Slice set — dev-login (`Defdo.AuthClient.Site` + `defdo_dev_idp`)

**Goal.** One vault-only contract in `defdo_auth_client` for where the IdP is and who is
signed in; a dev-only package, `defdo_dev_idp`, that mocks defdo_auth (OAuth2/OIDC +
bootstrap API) against THAT contract so every defdo app installs and signs in locally
through its unchanged plugs and its existing `/install` adapter; a prod build that carries
none of it, proven by a gate.

**Status.** `product.md` approved 2026-11-08 (owner); decisions revised the same day
(homologation, vault only, pinned tenant, tenant stack, my_mvno in-set). Slices authored
2026-11-08 (round 3), not started.

**Where the work happens.** 01–03 `defdo_auth_client`; 04–08 `defdo_dev_idp` (owner creates the repo; slice 04 copies the set under
`guides/slices/dev-idp/`); 09–11 host repos. Each slice names its repo.

## Documents

| File | Serves | Repo | Summary |
|---|---|---|---|
| `product.md` | — | — | approved product, decisions, wire contract |
| `00-conventions.md` | — | all | env rule, vault-only contract, codes table, wire contract, tenant stack |
| `01-authclient-site-contract.md` | P-05 | defdo_auth_client | `Site`: app record via vault Runtime set, customer records via Consumer, `put/2`, `sites/1`, `introspection/1` |
| `02-authclient-plug-sdk-on-site.md` | P-01 P-05 | defdo_auth_client | PKCE plug + SDK on `Site`; lazy `DevGuard` |
| `03-authclient-identity.md` | P-01 P-02 | defdo_auth_client | `Identity`, `Plug.Identity`, `LiveHook` → tag 0.15.0 |
| `04-devidp-package-bootstrap.md` | P-05 P-06 | defdo_dev_idp | host-supervised server, loopback ×2, boot states ready/unseeded, discovery |
| `05-devidp-authorize-and-token.md` | P-01 P-02 P-03 P-06 | defdo_dev_idp | picker (state-bound), PKCE S256, token, id_token + JWKS, legacy alias |
| `06-devidp-introspection-and-userinfo.md` | P-01 | defdo_dev_idp | both introspection endpoints, userinfo, sign-out |
| `07-devidp-seed-task.md` | P-07 | defdo_dev_idp | `mix defdo_dev_idp.seed`: `Site.put/2` records + tenants via `defdo_tenant_provision` |
| `08-devidp-gate-and-client-proof.md` | P-04 P-01 | defdo_dev_idp | fail-closed gate script (`release`/`deps`), `Gate`, integration test with the real plug → tag 0.1.0 |
| `09-host-gateway.md` | P-01..P-07 | defdo_gateway | adapter + credential store onto `Site`; `InstanceTenant` admin path removed; `AdminScope` vs pinned tenant |
| `10a-my-mvno-site-records.md` | P-05 P-07 | defdo_my_mvno | `Site` records, otp_app re-key, `authorize_url`/`token_auth_method` mapping, migration task |
| `10b-my-mvno-library-plug.md` | P-01 | defdo_my_mvno | replace `Defdo.Plug.DefdoAuthPKCE` with the library plug; registration/connection/actor type as contract fields |
| `10c-my-mvno-callers.md` | P-01 P-05 | defdo_my_mvno | move the 20 `VaultSecret` callers; delete `VaultSecret`/`SessionActorResolver` |
| `10d-my-mvno-tenant-edge-identity.md` | P-01 P-02 | defdo_my_mvno | `Defdo.TenantPlug` before PKCE, `Identity` + `LiveHook`, adapter onto `Site` |
| `11-host-cms-and-theme-hub.md` | P-01 P-04 P-05 | defdo_cms, defdo_theme_hub | cms own PKCE plug + adapters, hub `StudioAuthenticator` onto the contract |
| `12-verification.md` | P-04 P-05 | all | durable gate incl. no-private-seams and config-names-codes-only tests |

## Order and dependencies

01 → 02 → 03 → **tag defdo_auth_client 0.15.0** → 04 → 05 → 06 → 07 → 08 → **tag defdo_dev_idp 0.1.0** (after 07 AND 08) → 09 → 10a → 10b
→ 10c → 10d → 11. 12 lands with 08 and is extended by each host slice.

## Review rounds — what was missed and where the fix lives

| Round | Finding | Why missed | Fix in |
|---|---|---|---|
| 1 | `grep -vq` gates always pass | shell semantics | 09–11 Verification (`! … \| grep -q`) |
| 1 | gate script fail-open; runtime images have no mix | copied shape, not the image | 08 Step 1 |
| 1 | dev child in `:test` without config | assumed host test config | 04 (host-supervised, `enabled:`; tests `start_supervised!`) |
| 1 | per-host `site_check` | owner forbade per-host detection | removed; `Site.sites/1` |
| 1 | no enforcement when dep omitted | narrowed claim | 02 Step 4 `DevGuard` |
| 1 | bind-only loopback; unbound picker POST; dead branch | habits | 04, 05 |
| 2 | `Mix.env()` in dependency code is dead | compile vs runtime env | 00 rule, 01 `Env`, every package slice `! grep Mix.env()` |
| 2 | `Site.sites()` from a dependency `Application.start` | boot order | 04 (no `mod:`, host child after Repo/vault), 02 (lazy guard) |
| 2 | fresh DB chicken-and-egg | not modelled | 04 `:unseeded` state, 07 fresh-DB test |
| 2 | gateway platform tenant from DB selector; then static config; then resolver | wrong source | owner: vault only, pinned (00, 01, 09) |
| 2 | `sites/0` "first record"; atom/string payloads | guessed | 01 `sites/1`, `introspection/1`, `normalise/1` |
| 2 | my_mvno too large for one slice; then "must evolve" | scope | 10a–10d |
| 2 | own `Seeder` behaviour; provision_web misread as a writer, then as the seed path | did not read the package; owner: not now | 07 (`Site.put/2` + provision), product.md out-of-scope item |
| 2 | cms own PKCE plug + `_defdo_auth_me` cookie | not listed | 11 |
| 2 | Gate 3 via `Code.ensure_loaded?` stub; Gate 4 exemption untested | weak checks | 12 |

## Owner actions

Create `defdo-dev/defdo_dev_idp`; tags as above; lock-sha approvals for 09, 10a, 11.
