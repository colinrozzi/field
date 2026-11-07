# Mailbox test vectors

Each file is one case for a mailbox reader (field/SPEC-mailbox.md). The
events and their format are the chat vectors' (../chat/README.md), from any
scope: feed each one to the mailbox (which keeps the chat model), in array
order. `make` writes the files from the cases in it; edit those, not the
JSON. `run` checks field/mailmodel.wisp; `lib/mail-vectors` checks lib/mail.

## `expect`

| key | meaning |
|---|---|
| `addressed` | `{id: [names]}`: whom that event was addressed to when it arrived, compared as a sorted list |
| `box` | `{name: [ids]}`: everything addressed to name, in arrival order |
| `unread` | `{name: [ids]}`: what is addressed to name after its mark, in arrival order |
| `mark` | `{name: id}`: the mark from the mail.read events (`""` if none) |

Compare everything exactly; lists other than `addressed` in order.
