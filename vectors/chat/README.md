# Chat test vectors

Each file is one case for a chat reader (field/SPEC-chat.md):

```
{"name": "...", "about": "what it shows",
 "events": [[id, scope, kind, file_text], ...],
 "expect": {...}}
```

Feed `events` to the reader in array order, as if they arrived in that order in
a node's seen chain. Then every fact in `expect` must hold.

## The events

`file_text` is an event file as a node stores it and as `get` returns it
(field/SPEC-node.md, "The event file"): a line `sig <hex>`, then the
canonical text. Two parts are fake, so these vectors test chat readers only,
not a node's admission:

- **Ids** are made up (`a1000...0001` and so on), not the sha256 of the text.
  Readers take the id from the record, never from hashing the text.
- **Signatures** are 128 zeros. Chat readers do not check signatures (the node
  did that when it admitted the event). A node would refuse these events.

The `author` is server3's real `chat` public key, and each text is otherwise
canonical: the header lines in order, parents sorted, an exact `body` length.

## `expect`

| key | meaning |
|---|---|
| `msgs` | `{id: {field: value}}`: the message exists, and each named field has that value. Fields: `b` (branch), `from`, `re` (thread root, or `null`), `text`. |
| `branches` | `{name: {field: value}}`: the branch exists, and each named field has that value. Fields: `anchor` (id or `null`), `tips`, `members`, `state` (the whole key/value object). |
| `threads` | `{root id: {field: value}}`. Fields: `tips`, `replies` (in arrival order), `people`. |
| `no_msgs` | ids that must not be messages. |
| `no_branches` | names that must not be branches. |
| `tickets` | the complete list of `[n, branch]`, sorted by `n`. |

Compare `tips`, `members` and `people` as sets. Compare everything else
exactly. A fact that `expect` does not name is not tested.

## Status

`lib/chat` (`Index.add`) and `site/public/chat.js` (`add`) both pass all
eight cases (checked 2026-11-04 by running each reader's own code over these
files). `field/chatmodel.wisp`, the Wisp model, passes all eight too: `./run`
here checks it on a throwaway daemon of its own (2026-11-05).
`site/push.wisp` still builds its own smaller model.
