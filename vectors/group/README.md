# Group test vectors

Each file is one case for a group reader (field/SPEC-group.md). The events
and their format are the chat vectors' (../chat/README.md), from any scope:
feed each one, in array order, to the chat model, the group model and the
mailbox. `make` writes the files from the cases in it; edit those, not the
JSON. `run` checks field/groupmodel.wisp and mailmodel.wisp; `lib/chat-vectors
group` checks lib/chat and `lib/mail-vectors` lib/mail.

## `expect`

| key | meaning |
|---|---|
| `direct` | `{group: {member: role}}`: its direct members (a name or `group/H`) |
| `groups` | `{group: {name: role}}`: its effective members (section 3) |
| `open` | `{group: true or false}` |
| `members` | `{branch: [names]}`: the branch's members (section 5), compared sorted |
| `addressed` | `{id: [names]}`: whom the mailbox addressed that event to, compared sorted |

Compare everything exactly.
