# Identity test vectors

Each file is one case for an identity reader (field/SPEC-id.md). The events
and their format are the chat vectors' (../chat/README.md), in scope
`id/<name>`, each with its own `author`. `registrars` are the keys the
node's rules list for `id/`. Feed each event, in array order, to the model.
`make` writes the files from the cases in it; edit those, not the JSON.
`run` checks field/idmodel.wisp.

## `expect`

| key | meaning |
|---|---|
| `keys` | `{name: [[key, label], ...]}`: its current keys, in the order added |
| `retired` | `{name: [keys]}`: its retired keys, in order |
| `may_write` | `[[name, author, bool]]`: may that author write in `id/<name>` at all (not refused) |
| `key_ok` | `[[name, author, time, bool]]`: does the `id` rule admit an event from name, by author, claiming time (ms) |

Compare everything exactly.
