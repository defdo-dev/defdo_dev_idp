# Process map

Every long-lived activity in this package, and what answers "is it alive".

| Activity | Where it hangs | Starts after | Stopping it stops | Owns | Alive? |
|---|---|---|---|---|---|
| Dev IdP server (`Defdo.DevIdp`: `State` + `Store` + Bandit listener) | HOST application children, after Repo and vault, dev only (`enabled: true`); tests `start_supervised!` | `Boot.check/1` returned `{:ok, _}` | all dev logins | listener, codes/tokens/sessions, boot state | `Process.whereis(Defdo.DevIdp)` |
| `Defdo.DevIdp.Store` (GenServer + 3 ETS tables) | `Defdo.DevIdp` supervisor | the boot check passed | every in-flight login (codes) and dev session | codes, tokens, sessions | `:ets.whereis(:defdo_dev_idp_codes)` |
| `Defdo.DevIdp.Keys` (GenServer, one RSA key + the picker secret) | `Defdo.DevIdp` supervisor | the boot check passed | id_token signing, JWKS and every open picker page | the key pair, the picker secret | `Process.whereis(Defdo.DevIdp.Keys)` |

The supervisor is `:rest_for_one` in the order `State`, `Store`, `Keys`, listener: the listener
never serves a request without the state and the store it reads.

The package starts nothing on its own. It has no `mod:`.
