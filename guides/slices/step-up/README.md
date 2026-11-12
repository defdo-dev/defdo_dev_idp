---
kind: implementation
---

# step-up — `prompt=login`, `max_age` and `auth_time` in the dev IdP

A one-slice, internal set. The dev IdP has no product of its own: it stands in for
defdo_auth so a host's sign-in can be proven locally. The scenario this serves lives in
a host:

> core_back_office P-17 — "Entering configuration sends me to sign in again at the
> identity provider, even if I am already signed in there."
> (`defdo-dev/core_back_office`, slice `08-configuration-step-up.md`, where this slice is
> precondition **PD-1**.)

Conventions: [`../dev-idp/00-conventions.md`](../dev-idp/00-conventions.md).

| # | Slice | Depends on |
|---|---|---|
| 01 | [The dev IdP re-asks on `prompt=login` / `max_age` and says when you signed in](01-devidp-max-age-auth-time.md) | dev-idp slices 05 and 06 merged (PRs #2 and #3) |

Sibling preconditions, each in its own repo: `defdo_auth` (PR-2, the real provider) and
`defdo_auth_client` (PA-1, the client that verifies `auth_time`). The dev IdP must behave
like the real provider here, not better and not looser: a host proven against a dev IdP
that is more lenient than defdo_auth is not proven.
