---
kind: product
topic: dev-login
approved: 2026-11-08 (owner)
---

# Dev IdP (`defdo_dev_idp`) — product

**Approved:** 2026-11-08 (owner) — "apruebo y con tus recomendaciones", plus the design
change recorded below. Q1–Q6 of the first draft are answered in "Decisions".

## Who and why

A defdo developer (or an agent driving a look loop) wants to open an admin UI of a
defdo app on their own machine and see it. Today they cannot: every admin gate in the
estate admits only a session token the real IdP introspects as active, with the right
scope and the right tenant, and the tenant id itself comes from vault (`defdo_gateway`
`Plugs.AdminScope` calls the configured `:introspector`, default `Defdo.AuthClient.SDK`,
and compares against `Setup.AdminConfig.admin_tenant_id/0`, vault code
`admin-tenant-id`). Running that locally means a reachable IdP, a registered login
client with a `localhost` callback, and a seeded vault — three set-ups nobody has on a
laptop, so the Tidewave look loop (login, screenshot, console) is blocked and UI slices
ship unseen.

What the developer wants, in their words: "boot the app, pick who I am, land in the
admin shell, take screenshots, switch to a customer, do it again. Nothing of this may
exist in a production build."

## The design (owner, 2026-11-08)

> "que en dev exista como un server dev que entregue siempre lo que la app requiere para
> el perfil… solo compila en dev… similar a lo que hace test… así no dependemos del
> idp… siempre entregará el oauth2 flow igual… un paquete que solo corra en dev con mix
> y que si se omite en dev se rompa"

So, not a shortcut inside the host: a **separate dev-only package, `defdo_dev_idp`**,
that runs an **in-process mock IdP** started by the host's dev supervision tree and
speaks the **same OAuth2/OIDC flow** `defdo_auth` speaks — discovery, authorize (with a
profile picker instead of a login form), token with PKCE, introspection (both the
RFC 7662 endpoint and the app-API one), userinfo, JWKS. Host code paths — the
`defdo_auth_client` PKCE plug, the SDK introspection, the host's own admin plugs — run
**unchanged**; only the `site` points at the local server in `config/dev.exs`.

- Dependency declared `only: [:dev, :test]`. In `:prod` it is not fetched, not compiled,
  not in the release; a CI gate fails the pipeline if it is.
- A host that declares the dependency but lacks the configuration, or runs in dev with
  a `site` that is not the dev IdP, **fails at boot with a clear error**. A host in dev
  WITHOUT the dependency whose `Defdo.AuthClient.Site` resolves to a non-loopback site
  also fails at boot (`Defdo.AuthClient.DevSiteError`, raised by the client itself), so
  omitting the package breaks dev as the owner asked. No silent fallback to the real IdP.
- No env-var knobs. Profiles, port and the host's client registration are code in
  `config/dev.exs`, visible in the diff.

### Decisions (answers to the first draft's questions)

| # | Decision |
|---|---|
| Q1 | Seeding: `mix defdo_dev_idp.seed` writes the `Site` vault records directly through `Site.put/2` — the SAME writer every host uses after migration — and creates the dev tenants through `defdo_tenant_provision` (`Provision.run/2`, idempotent). It does not drive the install UI (owner 2026-11-08: "no hay que distraernos, las apps ya están instaladas"). Sample names invented, never real customers. |
| Q2 | **Standalone route**: the dev IdP is its own HTTP server on its own port; the picker is its `/oauth/authorize`. Nothing is mounted inside the host router. |
| Q3 | Compiled in **`:dev` and `:test`**. |
| Q4 | Host order: **defdo_gateway, defdo_my_mvno**, then defdo_cms, defdo_theme_hub. |
| Q5 | Each profile has a **fixed** `sub`, `email`, `name` (plus role, tenant, scopes). |
| Q6 | `sub` is **derived from role + tenant** (`"dev-" <> role <> "-" <> tenant`) so seeded membership rows keep matching across restarts. |
| Homologation | Owner 2026-11-08: "debemos homologar que todos usen el mismo patrón así no nos romperemos la cabeza con reinventar por cada app una lógica distinta de detección". **No per-host variants**: ONE contract in `defdo_auth_client` — `Defdo.AuthClient.Site` (where the IdP is, the pinned estate tenant + connection, login client, service/M2M client, registration/connection type) and `Defdo.AuthClient.Identity` (+ plug + LiveView hook). Every host migrates onto them, my_mvno included ("my_mvno debe evolucionar al método estandarizado"); no compat shims; host seams that duplicate the contract are rewritten and what is kept is recorded per host. |
| Vault only | Owner 2026-11-08: "debe salir de vault siempre para que se implemente bien". `Site` has ONE source, defdo_vault: the app record is read context-free through the vault runtime fetcher (`Defdo.Vault.Provider` / `Defdo.Vault.Runtime`, a declared set of codes), customer-tenant records through `Defdo.Vault.Consumer` under tenant context. Config files name the vault project and nothing else (no sites, ids, tenants or secrets; no env vars). |
| Pinned tenant | Owner 2026-11-08 + rule 2026-09-22: apps never get a tenant per instance; they live in the estate IdP tenant, PINNED per deployment and read from the vault record (`auth.tenant`, `auth.connection`). The gateway.s `InstanceTenant` DB-selector path for the admin tenant "está mal implementado" and is removed in slice 09; it is not modelled in the contract. |
| Tenant stack | Owner 2026-11-08: `defdo_tenant_provision` creates (step runner with idempotency), `defdo_tenant_provision_web` is the embedded install flow whose HOST adapter creates the local instance tenant and writes credentials, `defdo_tenant_plug` resolves the tenant at the request edge (+ LiveView `on_mount`), `defdo_tenant_boundary` carries context across processes (Task/Oban/PubSub). `Defdo.Tenant.Context` is what those packages use underneath. No slice creates tenants with raw inserts or passes tenant ids past the edge. |
| Repo | **Own repository `defdo-dev/defdo_dev_idp`** (recorded): a server with its own deps (Bandit, JOSE) that `defdo_auth_client` must never depend on; consumed by every host. The set is authored here because the client contract it quotes lives here; slice 04 copies it. |

## What exists today (verified 2026-11-08, read-only)

| Host | Where the gate decides | What it reads |
|---|---|---|
| defdo_gateway `main` | `lib/defdo_gateway_web/plugs/admin_scope.ex`: session `"access_token"` → `introspector().introspect_credential/1` → operator if `ai:admin` AND tenant == vault `admin-tenant-id`; customer if `Membership.tenants_for/1` non-empty | `Application.get_env(:defdo_gateway, :introspector, Defdo.AuthClient.SDK)`; `Setup.AdminConfig.fetch/0` needs four vault codes (`admin-oauth-site`, `admin-oauth-client-id`, `admin-oauth-client-secret`, `admin-tenant-id`) in the platform tenant's `"gateway"` project |
| defdo_cms | `lib/defdo_cms_web/hook/user.ex` → `Defdo.Cms.Auth.fetch_current_user/1` → `current_user_adapter().fetch_from_session/1`, then `enforcer().authorize_live(:cms_access, …)`; PKCE via `Defdo.Cms.Auth.AuthorizeCodeWithPKCEPlug` with `resolve_client: &Auth.resolve_oauth_client/1` | the PKCE session and the profile cache |
| defdo_my_mvno | `lib/defdo/hook/actor.ex` `{:with_actor, using_key: :user_token}` → `SessionActorResolver.resolve(user_token, access_token, tenant_id, pkce_session)`; roles from `Auth.Roles.roles_from_user/1` | session `"user_token"`, `"access_token"`, `"tenant_id"`, `"defdo_auth_pkce"` |
| defdo_theme_hub (standalone studio) | `Plug.StudioAuth` + `Hook.StudioAuth` `:require_subject`; closed unless `config :defdo_theme_hub, studio_authenticator: Mod` | `@callback authenticate(conn) :: {:ok, subject} \| :error` |

All four reach the IdP through `defdo_auth_client` 0.14.0:

- Login: `Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE` → `OAuth2.Client.authorize_url/2`
  (strategy `Defdo.DefdoAuth.Strategy.AuthCodePKCE`, PKCE `code_challenge` derived from
  the verifier) → callback exchanges the code with `grant_type=authorization_code` +
  `code_verifier` → `GET /openid/userinfo` must answer a map with `"sub"` → profile cached
  in `:defdo_auth_user_profile`, token stored in session `:user_token` + `:live_socket_id`.
- Token introspection: `Adapter.AuthCodePKCE.introspect/1` → `POST /oauth/introspect`
  (form: `token`, `client_id`, `client_secret`) → `%{"active" => bool, "scope" => "a b"}`.
- Credential introspection: `Defdo.AuthClient.SDK.introspect_credential/3` →
  `Defdo.AuthClient.CredentialIntrospection` → `POST /api/v1/introspect` (JSON
  `{"token": …}`, header `x-internal-token`) → `%{"active", "sub", "scopes" | "scope",
  "tenant" => %{"id" => …}}`.
- Config: `config :defdo_auth_client, Defdo.AuthClient, client: [site:, client_id:,
  client_secret:]` (`Defdo.AuthClient.Config.from_env/2`).

A mock IdP that serves exactly those endpoints with those shapes makes every host work
with a `site` change and nothing else.

## Scenarios

### P-01 — Boot and sign in as the operator

1. The developer runs `mix phx.server` in the host (dev env, no network IdP). The log
   shows one line: `defdo_dev_idp listening on http://localhost:4100 for :defdo_gateway
   (3 profiles)`.
2. They open `http://localhost:4000/admin`. The host's own PKCE plug redirects them to
   `http://localhost:4100/oauth/authorize?...` — the dev IdP's **profile picker**: the
   app name, one card per declared profile (`Operator · dev-tenant · ai:admin`,
   `Customer · acme`, …), a **Continue** button on each. No password, no secret.
3. They pick Operator.
4. They land back on `/admin` with the operator chrome — the same page a real operator
   sees, produced by the same callback, same session keys, same admin plug.

Done when: `/admin` renders as operator and `git diff` of the host shows only
`mix.exs`, `config/dev.exs`, the seed script and the dev supervision entry.

### P-02 — Switch to a customer without restarting

1. The developer opens `http://localhost:4100/` (the dev IdP's index) and presses
   **Sign out everywhere**, or clears the host cookie.
2. They open `/admin` again, the picker appears, they choose Customer · acme.
3. They are now in the customer portal of the same host; operator-only routes answer
   as they do for a real customer.

Done when: the role change is visible and no server restart happened.

### P-03 — Tidewave look loop runs it headless

1. An agent runs the Tidewave persistent-profile look loop: it loads `/admin`, follows
   the redirect to the picker, `POST`s the picker form with `profile=operator`, follows
   the callback, then screenshots `/admin/...` in both themes and at 390 px, then opens
   the Tidewave console.
2. Every step is a plain HTTP request; the picker also accepts
   `GET /oauth/authorize?...&profile=operator` so a script can skip the page.
3. The screenshots show the admin pages exactly as a real operator would see them.

Done when: a look script needs no human step between boot and the first screenshot.

### P-04 — A production build refuses

1. Someone builds the host with `MIX_ENV=prod`.
2. `defdo_dev_idp` is not in `mix deps.tree --only prod`, no `Elixir.Defdo.DevIdp.*`
   beam exists under the release's `lib/`, and `config/runtime.exs` never mentions it.
3. The host's release pipeline runs the gate the package ships
   (`scripts/ci/assert-no-dev-idp.sh <release-dir>`); it exits non-zero when any of the
   three is false, and it asserts the release dir exists before it looks.

Done when: the gate is in the release workflow of each host and is red on a build that
carries the package.

### P-05 — A host that forgets the configuration cannot boot in dev

1. A host adds the dependency but not the `config :defdo_dev_idp` block, or keeps
   `site:` pointing at `https://auth.defdo.dev`.
2. `mix phx.server` stops before the endpoint starts with:
   `** (Defdo.DevIdp.BootError) :defdo_gateway runs in :dev without a dev IdP. Add
   `config :defdo_dev_idp, ...` and point `config :defdo_auth_client, Defdo.AuthClient,
   client: [site: "http://localhost:4100"]` at it. See defdo_dev_idp README.`
3. Nothing reached the real IdP.

Done when: the test that removes the config asserts that exact error module and that
no outbound request was attempted.

### P-06 — It cannot be reached from another machine

1. The developer boots the host bound to `0.0.0.0` by mistake.
2. The dev IdP itself binds `127.0.0.1` only; a request from another address never
   arrives. Its `/oauth/token` additionally refuses a `redirect_uri` whose host is not
   `localhost`/`127.0.0.1`.

Done when: tests prove the bind address and the redirect_uri refusal.

### P-07 — Fresh clone to admin shell in four commands

1. A developer clones a host (gateway first), runs `mix setup`. The host's `setup` alias
   chains `defdo_dev_idp.seed`, which prints one line per profile:
   `seeded operator@dev-tenant: vault admin-* (4 codes), tenant Defdo Red` …
   `seeded customer@acme: tenant Acme (sample), membership dev-customer-acme`.
2. Running `mix defdo_dev_idp.seed` again prints `unchanged` for every row: the task is
   idempotent and never duplicates a tenant or a membership.
3. `mix phx.server`, open `/admin`, pick Operator on the dev IdP picker, land in the
   admin shell (P-01). Pick Customer · acme next time and land in the portal with the
   seeded membership (P-02).
4. `MIX_ENV=prod mix defdo_dev_idp.seed` refuses: `defdo_dev_idp.seed runs only in :dev
   and :test` — and in a prod build the task does not even exist.

Done when: a fresh clone reaches the admin shell with `mix setup && mix phx.server` and
a picker click, and the second seed run changes nothing.

## Views

The dev IdP's own pages, served from its port, plain HTML with the host's name:

- **`/`** — index: which host, which profiles, who is signed in (by cookie), **Sign out
  everywhere**. Primary action: none; it is a status page.
- **`/oauth/authorize`** — the **profile picker** (P-01, P-02, P-03). Primary action:
  Continue on a profile card. A `profile=` param skips the page.
- Machine endpoints, no UI: `/.well-known/openid-configuration`, `/.well-known/jwks.json`,
  `/oauth/token`, `/oauth/introspect`, `/openid/userinfo`, `/api/v1/introspect`.

The host's admin shell is the host's; this product adds no page to it.

## Ecosystem

- gap: one way to say where the IdP is and who is signed in — **improve** `defdo_auth_client` (slices 01–03); every host slice consumes that release.
- uses: defdo_auth_client@0.15 — `Site`, `Identity`, `LiveHook`, PKCE plug, SDK introspection (wire contract in `00-conventions.md`).
- uses: defdo_vault@0.21.2 — `Provider`/`Runtime` set, `Consumer.resolve_secret/3` + `upsert_secret/2`, dev/test `credentials` keyword (`transport: :local`).
- uses: defdo_tenant@0.24.1 — `Defdo.Tenant.Context.with_context/2` under the packages above.
- uses: defdo_tenant_provision@0.3.0 — `Provision.run/2` (idempotent step runner) inside the install.
- uses: defdo_tenant_provision_web@0.5.0 — unchanged in this set (first-run bootstrap of a virgin app; see Out of scope).
- uses: defdo_tenant_plug@0.3.1 — `Defdo.TenantPlug.Plug` resolver chain, `Defdo.TenantPlug.LiveView` `on_mount`.
- uses: defdo_tenant_boundary@0.7.0 — `Boundary.Task` / `Boundary.Oban` wherever a slice crosses a process.
- uses: bandit ~> 1.13, plug, jose, jason — the dev IdP server.
- gap: an OIDC-compliant mock IdP in Elixir that also answers defdo_auth.s bootstrap API — **derive** `defdo_dev_idp` (this set).
- gap: a prod-artifact gate every host runs — local to `defdo_dev_idp` (`scripts/ci/assert-no-dev-idp.sh`), copied into host pipelines.
- gap (defdo_vault): no in-process context-free single read outside the Runtime set; no cross-tenant record list — filed as `review-followup` issues, not blocking.

## Out of scope

- **No production impersonation.** Nothing here runs, compiles or is configurable in
  `:prod`. There is no "login as user X" against a real token.
- **No shared secrets.** The dev client id/secret and the dev internal token are
  literals in `config/dev.exs`, accepted only by the dev IdP, worthless elsewhere; the
  `id_token` key is generated at boot and lives in memory.
- **No IdP replacement.** The dev IdP implements the subset the clients call (listed
  above). No MFA, passkeys, consent screen, device flow, registration, CIBA, refresh
  rotation, app management API, or GraphQL. A host feature that needs one of those in
  dev extends the package in its own slice.
- **No host code change for admission.** If a host cannot admit a dev profile without
  editing its admin plug, that is a finding against the profile (wrong scope/tenant) or
  a missing seed, not a reason to add a bypass.
- **No test-suite rewrite.** Hosts keep their `IntrospectorStub`s and Mox setups; the
  package is for the running dev server and for browser/Playwright tests that want a
  real login.
- **provision_web first-run bootstrap (out of scope; owner 2026-11-08: "podría mejorarse… no hay que distraernos, las apps ya están instaladas").** `defdo_tenant_provision_web` is the virgin-app install (WordPress-style); the vault is empty at that moment, so its inputs (setup token, bootstrap site/token/registration key) come from process environment variables (`README.md:134-139`) and its output is written by HOST credential stores in host-specific shapes (gateway: four `admin-*` codes). Both clash with the vault-only rule. Not now: already-installed apps are migrated by the host slices (one-off `migrate_site_record`), new installs keep working. Issue text to file in defdo_tenant_provision_web (`review-followup`): "Bootstrap inputs read from the process environment clash with the no-knobs rule; credential output is host-shaped. Proposal: (a) end every install by writing the `Defdo.AuthClient.Site` app record through `Site.put/2` (pinned tenant, connection, browser + service client) via a default `CredentialStore`; (b) WordPress-style UX — bootstrap credentials entered in the install form; (c) `Install.run/2` public for headless installs."
- Later: a `mix defdo_dev_idp.cookie` task printing a ready session for curl loops; a
  Tidewave recipe in the skills repo.

## Open questions

None blocking. Approved 2026-11-08 with the decisions table above.
