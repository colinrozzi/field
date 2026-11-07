# Groups: specification

Status: ticket 0074, 2026-11-07 (ada; agreed with tova in the ticket's
branch). Step 2 of the design document `identity-groups-mailbox`.

A **group** is a set of members, each with a role, changed by events in its
own scope. Chat branches and documents point to a group instead of keeping
their own member lists. The mailbox (field/SPEC-mailbox.md) resolves a group
to its members. Groups hold names and roles only. Access (sealing 0056, node
write rules) is built on groups later; nothing here enforces read or write.

MUST, SHOULD and MAY are as in RFC 2119. Names are SPEC-chat 5.1's.

## 1. Events

A group `G` (a name) lives in scope `group/G`. Bodies are header lines
(SPEC-chat 4.1).

| kind | headers | effect |
|---|---|---|
| `group.add` | `from`, `who W`, `role R` (optional, default `write`) | `W` is a member with role `R` (a member already: its role becomes `R`) |
| `group.remove` | `from`, `who W` | `W` is no longer a member |
| `group.open` | `from`, `open yes` or `open no` | whether anyone may add or remove themselves (section 2) |

- **Roles**, lowest first: `read`, `write`, `admin`. Each member has one.
- **A member** `W` is a name, or another group written `group/H`. `/` is not
  a name character, so the two never clash. The same form works in the
  mailbox's `to` header (section 4).
- Parents: none.

## 2. Who may change a group

A reader applies `group.*` events in its arrival order. An event that is
not allowed is ignored. One is allowed if:

1. **The group is empty** (it has never had a member). The event's `from`
   becomes an `admin` member first, then the event applies. So the first
   event makes its writer admin.
2. Its `from` is an **admin** of the group (section 3, through nesting too).
3. The group is **open**, and the event is a `group.add` of `from` itself
   with role `read` or `write`, or a `group.remove` of `from` itself.

Even when allowed, an event is ignored if it would leave the group with no
`admin` among its effective members (section 3). A group always has an
admin. A group's very first event still makes its writer admin, even if the
rest of that event is ignored this way.

`from` is a body header, not checked against a key until identities (step 3).

**Known limit.** Whether an event is allowed depends on the group as it
stands when the event arrives, and arrival order differs between machines.
For example, an admin removed on one machine while their own change is
arriving elsewhere can leave two readers disagreeing. That is fine while
nothing is enforced; access (later) will need a better rule.

## 3. Members, through nesting

The **effective members** of `G` are a role for each name, worked out by
walking from `G`:

- A direct member that is a name `N` with role `R` gives `N: R`.
- A direct member `group/H` with role `R` gives every effective member
  `N: R2` of `H` as `N: min(R, R2)`, unless `H` is already on the path from
  `G` to here. Such a group adds nothing, so a cycle adds nothing. A group
  reached by two paths counts through each.
- A name reached more than once takes the highest role.

An unknown or empty `H` adds nothing.

## 4. The mailbox

A `to` word `group/G` addresses the effective members of `G` as they are
when the event arrives (all roles). Chat's rule (SPEC-mailbox 2) uses the
branch's members as section 5 defines them. `group.*` events themselves
have no rule.

## 5. Chat branches

A branch points to a group with `chat.set`, key `group`, value `G`.

- **A branch with a group:** its members are the group's effective members.
  Group-aware readers do not use `chat.join`, `chat.leave` or a post's
  author for its membership.
- **A branch without a group** (every branch today): its members are as in
  SPEC-chat 5.3. Old events keep working. A reader that does not know
  groups sees members this way for every branch.

Writers (lib/chat, the browser), from this ticket on:

- **A new branch:** first the group `group/B`, named after the branch, or
  `B-2`, `B-3` and so on if that group already exists. Its first event, a
  `group.add` of the creator, makes the creator admin. Then a `group.add` for
  each member with role `write`, `group.open yes` (a branch is open, like
  chat today), the `chat.branch`, and `chat.set group G`.
- **Joining, leaving, and the first post by a non-member** of an open
  branch: `group.add` or `group.remove` of the writer, so writing in a branch
  still makes you a member. In a closed group the writer refuses the post
  or join with a clear error (the writer, not the node).
- **Keeping old readers working:** for every member a group-aware writer
  adds or removes, it also writes the matching `chat.join` or `chat.leave`,
  so readers that do not know groups still see the members.
- **Existing branches:** `lib/chat ME group-make B` gives one a group. It
  writes the group from its current members (the writer as admin, the rest
  `write`, open), then `chat.set group`. Every branch is converted once
  parts 1 and 2 of this ticket are live and checked (part 3), so that only
  one membership model is left.

## 6. Documents: the split

A document moves out of chat into its own scope, `doc/D`, with a group, and
a chat branch for its discussion.

| kind | headers | text |
|---|---|---|
| `doc.set` | `from`, `key K` | the value; keys `title`, `status` (`draft`, `decided`), `group` (a group name), `branch` (the discussion branch), `wiki` (a topic, SPEC-doc 5) |
| `doc.edit` | `from`, `sec S`, `title T`, `after S2` (optional) | the section's body |

- **The model** is SPEC-doc 2 and 3, with the document taken from the scope
  instead of `in`:
  - `doc.set` is newest-wins by `(t, id)`, like `chat.set`.
  - `doc.edit` works like `chat.edit`: parents are the section's heads, and
    so are forks, joins, order and removal.
- **The document's members** are the effective members of its `group`.
  Nothing is enforced yet. A writer SHOULD only offer editing to `write` and
  `admin` members.
- **Comments and resolves** are chat messages in the `branch`, as in SPEC-doc
  1, with a `doc D` header beside `sec S`, so a branch can discuss more than
  one document.
- **The mailbox:** `doc.*` has no rule. Comments are chat messages, and
  reach people through chat's rule.
- **Old documents** (a branch with state `doc` and `chat.edit` events) stay
  readable. `lib/chat ME doc-move B` moves one:
  - It writes `doc/B`: `doc.set` for title, status, group (it makes the
    branch's group first if it has none) and `branch B`.
  - Then one `doc.edit` per section, carrying the current text and title.
    A forked section moves as its newest head. Each edit has a header
    `was <old edit id>`.
  - Last, `chat.set doc-moved B` on the old branch.

  Readers list a moved document once, as the new one, with a link back to
  the old branch for its history. The old branch keeps its edit history and
  remains the discussion branch.
- **New documents** go to `doc/` from this ticket on.

## 7. Rules and readers

Nodes must open `group/` and `doc/` to the chat keys (desktop `field/rules`,
server3 by deploy) **before** the first write (SPEC-mailbox 6).

Readers:
- `field/groupmodel.wisp` (used by mailmodel.wisp, and so by push.wisp).
- lib/chat, with READS raised so old processes stop.
- lib/mail, whose READS also goes up.
- `site/public/chat.js`.

node-chat posts `group.*` into `group/G` and `doc.*` into `doc/D`, as it
does `mail.read` into `mail/N`.

## 8. Conformance

A reader MUST pass every case in `field/vectors/group/`. Each case gives
events, then each group's effective members and roles, each branch's
members, and what the mailbox addresses.

Not in this ticket: enforcing roles (sealing, node write rules), ticket
groups, subscriptions.
