# Process map

Every long-lived activity in this package, and what answers "is it alive".

| Activity | Where it hangs | Starts after | Stopping it stops | Owns | Alive? |
|---|---|---|---|---|---|
| Dev IdP server (`Defdo.DevIdp`: `State` + `Store` + Bandit listener) | HOST application children, after Repo and vault, dev only (`enabled: true`); tests `start_supervised!` | `Boot.check/1` returned `{:ok, _}` | all dev logins | listener, codes/tokens/sessions, boot state | `Process.whereis(Defdo.DevIdp)` |

The supervisor is `:rest_for_one` in the order `State`, `Store`, listener: the listener
never serves a request without the state and the store it reads.

The package starts nothing on its own. It has no `mod:`.
