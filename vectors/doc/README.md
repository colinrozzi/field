# Document test vectors

Each file is one case for a document reader (field/SPEC-doc.md). The events
and their format are the chat vectors' (../chat/README.md): feed each one to
the chat model and then the document model, in array order. `make` writes
the files from the cases in it; edit those, not the JSON. `run` checks
field/docmodel.wisp; `lib/chat-vectors doc` checks lib/chat.

## `expect`

| key | meaning |
|---|---|
| `docs` | the complete list of `[branch, title, status]`, by branch |
| `sections` | `{branch: [[sec, heads, removed], ...]}`: the document's sections in order, each with its heads (newest first) and whether it is removed |
| `edits` | `{id: {field: value}}`. Fields: `b`, `sec`, `from`, `title`, `after`, `text` |
| `no_edits` | ids that must not be edits |
| `history` | `{branch: {sec: [ids]}}`, in arrival order |
| `comments` | `{branch: {sec: [ids]}}`, in arrival order |
| `resolved` | `{root id: "yes", "no" or ""}` |

Compare everything exactly, lists in order.
