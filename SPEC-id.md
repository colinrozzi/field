# Identity: specification

Status: draft, ticket 0079, 2026-11-07 (ada). Step 3 of the design document
`identity-groups-mailbox`. For tova to review before anything is built.

An **identity** is a name and its keys, and nothing else (colin: small
core). People, agents, services and machines are all identities, and every
identity has at least one key. A node can then check that an event "from
colin" is signed by a key colin holds, instead of trusting the `from`
header as it does today.

MUST, SHOULD and MAY are as in RFC 2119. Names are SPEC-chat 5.1's; keys
are ed25519 public keys, 64 lowercase hex (SPEC-node 3).

## 1. Events

Identity `N` lives in scope `id/N`. Bodies are header lines (SPEC-chat 4.1).

| kind | headers | effect |
|---|---|---|
| `id.key` | `from N`, `key K`, `label L` (optional: "desktop", "phone") | `K` is a key of `N` |
| `id.retire` | `from N`, `key K` | `K` is no longer a key of `N`, for good |

The event's **author** (the key that signed it, SPEC-node 2.1) says who may
write it:

1. **The first key** of `N` is written by a **registrar**: a key the node's
   rules list for `id/` (section 4). Nobody claims a name by writing it
   first.
2. **After that**, any current key of `N`, or a registrar, may add or
   retire a key of `N`. So a device can add the next device.
3. A retired key cannot be added again.
4. The last current key of `N` cannot be retired: an identity always keeps
   a key.

An event that breaks these is refused by the node (section 3), and readers
ignore it.

## 2. The model

A reader adds `id.*` events in arrival order. For each name it keeps the set
of **current keys** (with their labels) and the set of **retired keys**. An
event is applied only if section 1 allows it against that state.

Readers outside the node (lib/chat, the browser) MAY show a name's keys.
They do not need them: once the node checks (section 3), every admitted
event's `from` is true.

## 3. What the node checks

The node keeps the model of section 2, updated as it admits each `id.*`
event. Admission (SPEC-node 5) gains one rule word:

- **`id`**: a rules line `<prefix> id` admits an event whose author is a
  current key of the name in its body's `from` header. A body with no
  `from`, or a `from` with no identity, does not match.

Lines still combine as today: among the longest matching prefixes, any line
that admits the author admits the event. So `chat/ id` beside `chat/ <chat
key>` accepts both while things move.

The node checks events when it admits them, and never again. Events already
stored stay as they are.

**Order between nodes.** An event signed by a new key arrives at a peer
after the `id.key` that adds it, because peers copy in the sender's seen
order (SPEC-node 9.2). A retired key's later events are refused. Its
earlier ones were admitted when they arrived and stay.

## 4. Rules: from "the chat key may write" to "names may write"

| step | `chat/`, `mail/`, `group/`, `doc/` | `id/` |
|---|---|---|
| today | both nodes' `chat` keys | (closed) |
| A: identities exist | unchanged | the registrars: each node's own key (`desktop`, `server3`) |
| B: names sign | `id`, plus the `chat` keys | unchanged |
| C: chat key retired | `id`, plus the `chat` keys **before T** | unchanged |

- **Rules word `before T`:** step C needs one more rules form, `<prefix>
  <key> before <ms>`. It admits that key only for events whose `time` is
  less than `ms`.
  - So every old chat event, signed by the chat key, is still admitted when
    a new node copies the history.
  - The chat key can no longer write anything new: node-chat stops using
    it, and nothing it writes after T is admitted.
- **Time is a claim (SPEC-node 2.1).** Whoever holds the chat key could
  still backdate an event. Nobody holds it but the node daemons, so this is
  the same trust as today, and only for the past.
- **Groups as write rules.** "Names in group G may write scope S" is a
  later step that sits on top of this one, with sealing (0056). It would be
  a rules word `group:G`, admitting an author who is a current key of an
  effective writer of G. Groups and documents live in the field, so the
  node would keep the group model too. Not in this ticket.

## 5. Who holds which keys

Keys stay in daemons (SPEC-node 3). This ticket gives every identity its
own key name.

| identity | key name | in which daemon | added by |
|---|---|---|---|
| each agent (ada, tova, ...) | `id.ada` | desktop | `dispatch`, when it starts the agent (the registrar signs the `id.key`) |
| colin, desktop | `id.colin.desktop` | desktop | the registrar, once |
| colin, browser | see 6 | | |
| services: `github-events`, `ops`, `agents` (feeds), `desk` | their existing keys | desktop | the registrar, once |
| each node: `desktop`, `server3` | their node keys | their own | themselves; they are the registrars |

**Honest limit.** Every agent's session runs in one daemon on the desktop,
and any session there can `(sign NAME ...)` with any key. So per-agent keys
separate the names in the record, but they don't stop one agent signing as
another. That is the same as today with `from`. Real separation needs each
key in a holder only its owner can reach (a Theater actor with narrowed
permissions). That is a later step, and this one makes it possible.

**node-chat** signs with the key of the request's `from`, `id.<from>`, and
refuses a name with no key: "no key for NAME; it needs an identity first".
During step B, a name without a key falls back to the chat key.

## 6. The browser

Two ways, in order:

1. **live.wisp signs for colin after login** (step B).
   - server3's daemon holds `id.colin.server3`, added by the registrar.
   - live.wisp signs colin's writes with it, as it already writes as colin.
   - The login is the check. It is one key for every browser.
2. **A key per device, in the browser** (later).
   - WebCrypto Ed25519, which current Chrome, Safari and Firefox have. The
     key is non-extractable and kept in IndexedDB.
   - To add a device, colin shows its public key and a current key of colin
     signs the `id.key`, for example `lib/chat colin id-add colin <key>
     phone` on the desktop.
   - The page then signs events itself, and live.wisp only passes them to
     the node.

I'd do 1 in this ticket and 2 as its own.

## 7. Tools and readers

- `field/idmodel.wisp`: the model, used by the node (store.wisp) for the
  check, and by node-chat to find a name's key.
- `field/vectors/id/`: events, then each name's current and retired keys,
  and which (author, scope, from) the `id` rule admits.
- lib/chat:
  - `id NAME` shows a name's keys and labels.
  - `id-new NAME` creates the key in this daemon and has the registrar
    write its first `id.key`. It goes through node-chat, which holds the
    registrar key.
  - `id-add NAME KEY [LABEL]` and `id-retire NAME KEY`.
- Rules on every node before the first write (SPEC-mailbox 6). New files go
  in the deploy list, and each changed service needs `--restart`.

## 8. Order of work

1. idmodel, vectors, the node reading `id/` (not enforcing), rules opening
   `id/` to the registrars, and the lib/chat verbs.
2. Keys for everyone (section 5), and live.wisp signing as colin.
   node-chat signs per name. Rules step B.
3. After a quiet period with every writer signing as itself, rules step C:
   the chat key only before T.

Not in this ticket: groups as write rules, sealing, per-device browser keys,
and key holders separated per agent.
