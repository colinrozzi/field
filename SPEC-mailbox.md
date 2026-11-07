# The mailbox: specification

Status: ticket 0073, 2026-11-07 (ada; agreed with tova in the ticket's
branch). Step 1 of the design document `identity-groups-mailbox`.

A **mailbox** is a view, not new events: for each name, the events in any
scope that are addressed to it, in the reader's arrival order, plus a read
mark. Delivery (agents' wake, the unread count, phone push) reads the
mailbox instead of chat.

MUST, SHOULD and MAY are as in RFC 2119. Names are SPEC-chat 5.1's.

## 1. Addressing

An event is **addressed** to name `N` when `N` is not its `from` and one of:

1. its body has a `to` header and `N` is one of its words;
2. its kind's rule (section 2) gives `N`.

Headers are read as in SPEC-chat 4.1 (split at the first `\n\n`; first key
wins). A body that has no header lines simply has no `to` and no `from`.

**`to`**: names, separated by single spaces (`to tova ada`). Words that are
not names are ignored. Any kind may carry it; a writer adds it to reach
someone who is not reached otherwise. (Groups come in step 2; until then a
`to` word is always a name.)

`from` is a body header and not checked against a key until identities
(step 3); the mailbox trusts it as chat does today.

Addressing is decided **once, when the event arrives**, against the models
as they are just before it (the chat model has already added the event
itself). A later join does not deliver earlier events.

Scopes read: every scope the node shares, except `field/` (the node's own
events). `mail/` scopes hold read marks (section 3), never addressed.

## 2. Kind rules

A kind declares its rule in its own spec, as "a `<kind>` event is addressed
to ...", computed from that system's model. A mailbox reader implements the
rules of the kinds it knows; an event whose kind has no rule is addressed
only by `to`. Rules are fixed in the reader for now (rules as code is an
open question of the design).

The only rule in step 1 is chat's (SPEC-chat 6, "Reaches", moved here and
referred to from there):

- **`chat.msg`** in `chat/main`: the branch's members; for a reply, also the
  thread's people; and every `N` whose `@N` its text matches
  (`(^|[^A-Za-z0-9_@])@N\b`).

Other chat kinds (join, set, edit, ...) have no rule; `to` still works on
them.

## 3. The read mark

Each name has one mark: the id of an event. Every event addressed to `N`
that the reader received **at or before** the mark (in its own arrival
order) is read; the rest are **unread**. A mark only moves forward.

Marks are events, so every device and every reader agrees:

| kind | scope | body |
|---|---|---|
| `mail.read` | `mail/<name>` | `from <name>\nupto <event id>\n` |

A reader's mark for `N` is the `upto`, among the `mail.read` events in
`mail/N` whose `from` is `N`, that comes latest in its own arrival order. One
whose `upto` has not arrived yet waits until it does. (A mark from another
device whose node is ahead never marks read what this reader has not shown.)

Writers: marks live in the field forever (and in the browser's snapshot),
so write few. A reader keeps a **local mark** (the one `wait` uses) and
writes a `mail.read` for a name at most once every 10 minutes, naming its
local mark, and when it exits if it can. The browser writes when colin
opens things, debounced the same way. A local mark is never behind the
field's mark.

**Known limit.** Arrival order differs between machines: machine A can
mark read, up to `upto`, an event that machine B received before `upto` but
A received after it and never showed. Fine for step 1; a later fix could be
a set of ids or a mark per scope.

Moving from chat: a reader starting with no `mail.read` for `N` takes chat's
`read[N]` (lib/chat's index: the message with that seq) as its first mark,
so no one is woken for what they already read. While old processes run,
`lib/mail` also advances chat's `read[N]` when it marks chat messages read,
so `lib/chat unread` and an old `lib/chat wait` agree with it.

## 4. What wait prints

`lib/mail NAME wait` blocks until `N` has unread events, prints them oldest
first, then moves the local mark (section 3). Output for a `chat.msg` is exactly what `lib/chat
wait` prints today (`chat <branch> HH:MM <who> [<id8>]: <text>`, ` re
[<id8>]` for a reply, continuation lines indented, then the one hint line),
so agents see no change. Any other event prints as

```
mail <kind> <scope> HH:MM <from> [<id8>]: <the text, as for chat>
```

`lib/mail NAME unread` prints the same without waiting or moving the mark;
`lib/wait-message` calls `lib/mail wait` where it calls `lib/chat wait`
today.

## 5. Moving delivery

- **wait** (agents): `lib/wait-message` races `theater-repl wait` with
  `lib/mail NAME wait` instead of `lib/chat NAME wait`. Same output.
- **unread count**: `/today`'s total badge = colin's mailbox unread count.
  Per-branch dots stay as they are (what colin has opened, kept in the
  browser). Opening a branch or thread writes `mail.read` up to the newest
  addressed event before which everything has been opened.
- **push** (phone): `push.wisp` pushes each event newly addressed to colin
  (mailmodel instead of `chat-reaches`), but only a `chat.msg` or an event
  addressed by an explicit `to`, so a busy kind that later gets a rule
  cannot flood the phone. A chat message's payload stays the same; others
  get `{title: "<from>: <kind>", body: text, url: /today}`.

## 6. Readers

- `field/mailmodel.wisp`: the model (like chatmodel.wisp), used by
  push.wisp; follows every scope with the chat model inside.
- `lib/mail`: Python, for wait and unread; its own index in `run/mail/`
  (its own lock and version guard, as lib/chat's section 8 learned), so the
  chat index is not migrated. It keeps lib/chat's model inside, and reads it
  again from the start when lib/chat's READS changes. `lib/mail-vectors`
  checks it.
- `site/public/chat.js`: the badge and mark.

Posting `mail.read`: node-chat (field/chat.wisp) also accepts kind
`mail.read` in scope `mail/<name>`, signed with the chat key like every chat
event, until identities give each name its own key. A node's rules
(SPEC-node 5) must open `mail/` to the chat keys, on every node before the
first `mail.read` is written: a peer that refuses one event stops syncing
from that node until its rules change (SPEC-node 9.2, step 5).

## 7. Conformance

A reader MUST pass every case in `field/vectors/mail/`: events in, then each
name's mailbox (ids in order) and unread ids after the marks.

Not in step 1: groups as `to` targets, subscriptions and filters, email and
digests.
