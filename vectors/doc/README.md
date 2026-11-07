# Document test vectors

Each file is one case for a document reader (field/SPEC-doc.md). The events
and their format are the chat vectors' (../chat/README.md): feed each one to
the chat model and then the document model, in array order. `make` writes
the files from the cases in it; edit those, not the JSON. `run` checks
field/docmodel.wisp; `lib/chat-vectors doc` checks lib/chat.

## `expect`

| key | meaning |
|---|---|
| `docs` | the complete list of `[name, title, status]`, by name: a branch, or `doc/<D>` for a document in its own scope (field/SPEC-group.md 6) |
| `sections` | `{name: [[sec, heads, removed], ...]}`: the document's sections in order, each with its heads (newest first) and whether it is removed |
| `edits` | `{id: {field: value}}`. Fields: `b`, `sec`, `from`, `title`, `after`, `text` |
| `no_edits` | ids that must not be edits |
| `history` | `{name: {sec: [ids]}}`, in arrival order |
| `comments` | `{name: {sec: [ids]}}`, in arrival order |
| `resolved` | `{root id: "yes", "no" or ""}` |
| `links` | `{name: [[D, S], ...]}`: the document's links (SPEC-doc 5), `S` empty for `[[D]]`, sorted |
| `backlinks` | `{name: [names]}`: the documents linking to it, sorted |
| `wiki` | `{name: topic}`: its `wiki` value, empty if none |

Compare everything exactly, lists in order.
