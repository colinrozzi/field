# The field node: specification

Status: describes the code as of 2026-11-04 (ticket 0062). Sources:
`field/store.wisp`, `server.wisp`, `peer.wisp`, `gate.wisp`, `client.wisp`,
`feed.wisp`, `serve-*.wisp`, `desktop/`, `server3/`. Where `DESIGN.md` says
something else, the code wins, and the difference is listed under
"Divergences" at the end.

The words MUST, MUST NOT, SHOULD and MAY mean what RFC 2119 says. A rule the
reference code enforces is written MUST. A rule it only follows is SHOULD.

## 1. Overview

A **node** holds **events**. An event is a short, signed text record. Its id
is the sha256 of its text. A node:

- checks an event and **admits** it (section 5);
- records each admission in its own chain of `field.seen` events, the **seen
  chain** (section 6), which is the node's log;
- answers requests over TCP: `head`, `follow`, `get`, `pull`, `admit`,
  `watch` (section 8);
- copies events from other nodes by pulling their seen chains (section 9);
- may sit behind a **gate**, a TLS listener that admits only nodes holding a
  listed key (section 10).

All text is UTF-8. All lengths are counts of **bytes**. All line ends are a
single LF (0x0A), never CR LF.

## 2. The event

### 2.1 Fields

| field | value |
|---|---|
| `author` | the author's ed25519 public key: 32 bytes as 64 lowercase hex characters |
| `scope` | which part of the field the event belongs to, e.g. `chat/main` |
| `kind` | what it is, e.g. `chat.msg`, `github.pr.merged` |
| `time` | the author's clock, milliseconds since the Unix epoch, decimal. A claim: the node never orders by it |
| `parent` | zero or more ids of events this one follows |
| `link` | zero or more references to things outside the field, as free text (e.g. `blob <sha256> <size> <type>`). The node stores links and never reads them |
| `body` | at most 16384 bytes; its format belongs to the kind |

`scope`, `kind`, each parent and each link MUST NOT contain LF. `scope` and
`kind` SHOULD NOT contain a space (section 6 and section 8 split on spaces;
the reference does not refuse one). A parent SHOULD be 64 lowercase hex
characters; in practice it MUST be the id of an event the node holds (rule 5
in section 5).

### 2.2 The canonical text

An event has exactly one text. In order, each line ending in LF:

```
field 1
author <author>
scope <scope>
kind <kind>
time <time>
parent <id>        zero or more, sorted, no repeats
link <link>        zero or more, sorted, no repeats
body <n>
<n bytes of body>
```

- `<time>` is one or more ASCII digits. It is kept as written: `0123` is a
  valid time and stays `0123`.
- `<n>` is one or more ASCII digits, the body's length in bytes. The body
  follows the `body` line at once and runs to the end of the text. It needs
  no final LF, and may contain anything, LFs included.
- Parents are sorted by **byte order** (memcmp; a string sorts before any
  longer string it begins), with repeats removed. Links the same, sorted
  among themselves.
- Nothing else may appear: no extra lines, no other order, no trailing bytes.

Example (`author` is the RFC 8032 test-1 public key; 317 bytes):

```
field 1\n
author d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n
scope chat/main\n
kind chat.msg\n
time 1793541600000\n
parent 0f2c000000000000000000000000000000000000000000000000000000000000\n
parent 9a71000000000000000000000000000000000000000000000000000000000000\n
body 36\n
from colin\nin general\n\nhello, field\n
```

### 2.3 The id

**id** = sha256 of the canonical text's bytes, written as 64 lowercase hex
characters. The `sig` line is not hashed. For the example:

```
30fdea09da769f26364a0e579d1b126e41d50aa8c8d167b271052f27af3a6148
```

### 2.4 The signature

**sig** = the ed25519 signature (RFC 8032, pure Ed25519) by the author's key
over the **64 ASCII bytes of the id's hex**, not over the 32 raw hash bytes
and not over the text. It is written as 128 lowercase hex characters.

The example, signed with the RFC 8032 test-1 seed
`9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60`:

```
0b7f450ad2cc9fb24a574d384c53659993361e69c04ffefebd73150257977361508ea40eba3849c81badf7b9ba37a8c933aecbfe23ffd12975b0888adc3c9c06
```

Verification is **strict** (ed25519-dalek `verify_strict`): it refuses
small-order public keys and non-canonical signatures. Hex digits in the key
and signature are read case-blind; writers MUST write lowercase.

Ed25519 is deterministic, so one author signing one text always gives the
same sig. The sig travels with the event but is not part of its identity.

### 2.5 The event file

A node stores, and `get` returns, the **event file**:

```
sig <128 hex>\n<canonical text>
```

The example's file is 450 bytes: `sig ` (4), the signature (128), LF (1),
the text (317).

### 2.6 Parsing

A reader of canonical text MUST accept exactly the form in 2.2 and refuse
everything else. The reference parses line by line, then encodes what it
parsed and compares: if the bytes differ, the text is "not canonical". The
checks, in order, with the reference's reason strings:

| check | reason |
|---|---|
| first line is `field 1` | `not a field 1 event` |
| lines `author `, `scope `, `kind `, `time ` follow in order | `missing header line` |
| time is one or more digits | `bad time` |
| after any `parent ` and then `link ` lines, a `body ` line | `missing body line` |
| its length is one or more digits | `bad body length` |
| length <= 16384 | `body too long` |
| the text ends exactly `<n>` bytes after the `body` line's LF | `wrong body length` |
| re-encoding gives the same bytes (sorted, no repeats) | `not canonical` |

## 3. Authors and keys

An author is an ed25519 key. Keys stay in the daemon: a key named `NAME` is
the file `<keys dir>/NAME.key` holding the 32-byte seed as 64 hex characters
(surrounding whitespace ignored). Key names are 1 to 64 bytes of `A-Z a-z 0-9 .
_ -`. Wisp code never sees a seed; it calls `(sign NAME bytes)`,
`(key-public NAME)` (the 64-hex public key) and `(verify pub sig bytes)`.
The node and client.wisp create a missing key (`key-new`) the first time they need it.

Keys in use:

| name | where | signs |
|---|---|---|
| `desktop`, `server3` | each node | that node's seen chain; the desktop's gate handshake |
| `chat` | each node | every chat event (field/SPEC-chat.md) |
| `github-events`, `agents`, `ops` | desktop | feed events (section 11) |

## 4. Scopes

Every event has one scope, a `/`-separated name. Two prefixes mean
something to the node:

- **`private/`**: events in these scopes stay on the node. No request may
  send or name them: `pull` and `follow` MUST leave their entries out, and
  `get` MUST answer `no such event` (sections 8.3-8.5). Only code in the
  node's own session reads them.
- **`field/seen/<node>`**: the scope of that node's seen chain (section 6).

Which authors may write which scopes is the node's **rules** (section 5).

## 5. Admission

`admit(sig, text)` returns the event's id or a reason. Steps, in order:

1. id = sha256(text).
2. If the node already holds an event with this id, return the id. **Nothing
   else is checked** (not even the sig): a repeat is a no-op.
3. Parse the text (2.6). On failure, return the reason.
4. Verify sig against the author and id (2.4). Failure: `bad signature`.
5. Check the rules (below). Failure: `author may not write to this scope`.
6. Every parent must be an event the node holds. Failure: `missing parent
   <first missing id>`. The event is refused, not kept waiting; the sender
   must send parents first.
7. Store it: write the marker `field/unseen/<id>` (empty), write the event
   file, add one seen event naming it (section 6), delete the marker.
8. Return the id.

A reason is returned with the prefix `error: `, e.g. `error: bad signature`.

**Rules.** The file `field/rules` holds lines `<scope prefix> <who>`, where
`<who>` is one of:

- an author key, or `*`;
- `id`: the author is a key of the identity named by the body's `from`
  header (field/SPEC-id.md 3);
- `<key> before <ms>` (four words): that key, for events whose `time` is
  less than `ms`.

Any other line is ignored.

- If the file is missing or empty, every scope is open to every author.
- Otherwise, take the lines whose prefix the scope starts with (a plain
  string prefix: `chat/` matches `chat/main`, and `ab` matches `abc`). Among
  them, take those with the **longest** prefix. The author may write if one
  of those admits it.
- In scope `id/<name>`, the matching lines' keys are the **registrars**, and
  the author may write if it is a registrar or any key the name has ever
  had. The node keeps identities in `field/ids/` as it admits `id.*` events
  (idmodel.wisp), and ignores an event that SPEC-id 1 does not allow.
- A scope no line matches is closed.

The desktop's rules today: `github/`, `agents/`, `ops/`; `chat/`, `mail/`,
`group/` and `doc/` (two keys each: each node's `chat`); `field/notes` (two
keys); `id/` (the node keys, the registrars). Each prefix names its
writers.

Rules are local: two nodes with different rules can disagree about an event.

## 6. The seen chain

A node records what it admits as events. Each admission (step 7) appends one
**seen event**, signed by the node's own key (the key named after the node:
`desktop`, `server3`):

| field | value |
|---|---|
| author | the node's public key |
| scope | `field/seen/<node name>` |
| kind | `field.seen` |
| time | now, ms |
| parent | the previous seen event (the head), or none for the first |
| link | none |
| body | one line per admitted event: `<id> <scope> <kind>\n` |

Seen events are stored like any event (`get` returns them) but are **never
themselves recorded** in a seen chain, so no seen causes another, and they are
not admitted through the rules. A seen event names one event, except at
start (section 7), when it names all unrecorded ones.

The seen chain is the node's log. Because of rule 6, an event's parents are
named no later than the event itself, so the chain is in topological order.

**Cursors** are seen-event ids. "After cursor C" means the seen events that
follow C in this node's chain; the cursor "" (sent as `-`) means from the
first. A cursor from another node's chain, or from a wiped node's old chain,
names nothing here: following after it gives nothing, forever (Divergences).

**Following.** `follow-n(after, scope, kind prefix, n)`:

1. Walk forward from `after`, up to `n` seen events.
2. `cursor` = the last seen event walked, or `after` if none.
3. `more` = 1 if a seen event follows `cursor` and the walk stopped only at
   `n`; else 0.
4. `entries` = the body lines of the walked events, oldest first, as `(id
   scope kind)`, keeping those whose scope **equals** `scope` (or all, if
   scope is "") and whose kind **starts with** the kind prefix.

A walk stops early, with more = 0, at a seen event it cannot read.

**Subscribers.** `field/subs` holds lines `<actor> <scope> <kind prefix>`.
After each seen event, the node sends each listed actor the Theater message
`field: seen <seen id>`. It is a hint: subscribers follow from their own
cursor, so a lost message costs nothing. (The scope and prefix are recorded
but not used to filter.)

## 7. The store on disk

All state is in files, relative to the node's session directory. Nothing
lives only in memory.

| path | holds |
|---|---|
| `field/events/<id[0:2]>/<id[2:64]>` | the event file (2.5), written durably |
| `field/seen-head` | the id of the newest seen event; absent or empty: none |
| `field/seen-first` | the id of the first seen event |
| `field/seen-next/<id>` | the id of the seen event after `<id>` (the chain links backwards through `parent`; this file links forwards) |
| `field/unseen/<id>` | an admitted event not yet in the chain |
| `field/rules` | admission rules (section 5) |
| `field/ids/<name>/keys`, `retired`, `ever` | identities, kept as `id.*` events are admitted (field/SPEC-id.md) |
| `field/node` | this node's name, which is its key's name (node-chat signs `id.*` with it) |
| `field/subs` | subscribers (section 6) |
| `field/conn/<cid>` | request bytes received but not yet handled, per connection |
| `field/watchers` | connection ids that sent `watch`, one per line |
| `field/peers/<name>` | a peer's cursor in the remote chain (section 9) |
| `field/peers/<name>.watch` | the open watch connection's id, or empty |
| `field/gate/<cid>` | the gate's state per connection (section 10) |
| `field/gate-keys` | the nodes the gate lets in (section 10) |

Recording a seen event writes, in this order: the event file;
`seen-first` (if there was no head) or `seen-next/<old head>`; `seen-head`;
then deletes the `unseen` markers; then tells subscribers.

**Start.** Make the directories `field`, `field/events`, `field/seen-next`,
`field/unseen`. If `field/unseen/` holds any names (a crash after step 7
began), record them all in one seen event. A marker whose event file is
missing gives no line. The server then empties `field/conn/` and
`field/watchers` and listens.

## 8. The TCP protocol

The node listens on `127.0.0.1:7800` and only ever serves: it never makes a
request itself, so two nodes cannot deadlock on each other. A connection
carries any number of requests. Replies come in request order.

### 8.1 Framing

A **request** is one line: words separated by single spaces (empty words are
dropped), ended by LF. `admit` adds a body. Empty lines are skipped.

A **reply** is

```
ok <n>\n<n bytes of payload>
err <n>\n<n bytes of reason>
```

with `<n>` in decimal. A request may arrive in pieces; the node buffers the
bytes until it has a whole request.

**Limit.** If the bytes buffered on a connection (left over plus newly
received) exceed **20000** (MAX-REQUEST), the node replies `err 17\nrequest
too large` and closes the connection.

An unknown verb gets `err 15\nunknown request`.

### 8.2 `head`

```
-> head\n
<- ok 64\n<the seen head id>          (ok 0\n if the chain is empty)
```

### 8.3 `follow <after|-> <scope|-> <kind|->`

One page of section 6's follow, with n = **16** (FOLLOW-PAGE). `-` means ""
for each argument. Entries whose scope starts with `private/` are left out;
the cursor still moves past them.

```
<- ok <n>\n<cursor|-> <more>\n<id> <scope> <kind>\n...
```

With fewer than three arguments: `err 35\nfollow wants <after> <scope>
<kind>`. Scope is matched exactly; kind as a prefix. The cursor is `-` only
when the chain is empty and `after` was `-`.

### 8.4 `get <id>`

```
<- ok <n>\n<the event file>
<- err 13\nno such event      (also for a private/ event, and for any id
                               that is not 64 lowercase hex characters)
```

No argument: `err 14\nget wants <id>`.

### 8.5 `pull <after|->`

Like follow with no filter and n = **64** (PULL-PAGE), but the events come
inline:

```
<- ok <n>\n<cursor|-> <more>\n
   then per entry: <id> <scope> <kind> <len>\n<len bytes: the event file>
```

Entries whose scope starts with `private/` are left out, and so are entries
whose file cannot be read. The cursor still moves past them. No argument:
`err 18\npull wants <after>`.

Example, a page holding only the event of 2.2:

```
ok 605\n
<seen id> 0\n
30fdea09...6148 chat/main chat.msg 450\n
sig 0b7f45...9c06\nfield 1\n...hello, field\n
```

(605 = 67 for `<seen id> 0\n` + 88 for the record line + 450 for the file.)

### 8.6 `admit <sig> <len>`

```
-> admit <sig> <len>\n<len bytes of canonical text>
<- ok 64\n<id>
<- err <n>\nerror: <reason>          (section 5)
```

`<len>` MUST be one or more digits. Missing words or a bad length give `err
23\nadmit wants <sig> <len>`, and the node goes on reading **at the next
line**, so the body that followed is read as requests. The node waits until
all `<len>` bytes have arrived.

After a successful admit that changed the seen head, the node tells every
watcher (8.7).

### 8.7 `watch`

```
-> watch\n
<- ok <n>\n<the seen head now>
<- ok 64\n<new seen head>      sent unasked, each time an admit on any
                                connection adds a seen event
```

A watch is a hint, like a subscription: the watcher still pulls from its own
cursor. The connection may carry other requests too; their replies interleave
with the notices. The watcher list is emptied when the node starts and a
connection leaves it when it closes.

## 9. Peers: following another node

Following is not the node's job: a separate **peer** session dials both
nodes as a client, so it can block on the network without holding up a node.
Each copy direction has a name, which names its cursor file
`field/peers/<name>`.

### 9.1 Addresses

- `host:port`: plain TCP (loopback).
- `tls:<server name>:<host>:<port>:<key name>`: through a gate (section 10).
  Exactly four `:`-separated parts after `tls:`, so a host cannot contain
  `:`.

### 9.2 Pull-on

One call, `pull(name, remote, local, wants)`, dials both and repeats up to
**8** times (PULLS):

1. Send `pull <cursor|->` to the remote.
2. If it answers `err`: stop, "pull failed". There is no fallback to
   `follow` and `get`.
3. If the reply's cursor is `-` or equals ours: stop, "idle".
4. For each record, in order, whose scope starts with one of the **WANTS**
   prefixes (an empty list wants everything): send the event file to the
   local node as `admit <sig> <len>\n<text>`, splitting the file at its
   first LF. Records not wanted are skipped.
5. If any admit fails, stop with "copy failed" and **do not move the
   cursor**. The same page is tried again next time.
6. Write the new cursor durably.
7. If more = 1, go again (up to 8 pages), then answer "more" if the remote
   still has more; else "copied".

Admitting an event the local node already holds is a no-op that succeeds,
so a crash repeats work and loses nothing, and events stop after one hop:
when B pulls back from A what A got from B, every admit is a repeat.

Because of step 5, an event the local node refuses (its rules close the
scope, or a parent was not wanted) stops that direction until the rules or
WANTS change. Remote events are admitted under the local node's own rules.

### 9.3 Waking

A peer opens a `watch` (8.7) on each node it pulls from and pulls whenever
that connection receives data. As deployed on the desktop
(`desktop/serve-peer.wisp`), one session runs both directions through
server3's gate: `server3` pulls server3 into the desktop, and `server3-push`
pulls the desktop into server3. Both WANTS lists are empty. While a pull
answers "more" it pulls again every 50 ms. A 60 s tick pulls both ways and
reopens any watch that has closed.

## 10. The gate

A gate is a node's public door (server3: `0.0.0.0:7443`). It ends TLS,
makes the client prove which node it is, and then joins the client to the
node's loopback port, passing bytes both ways untouched. The node itself
never listens publicly.

### 10.1 Handshake

```
client                                  gate
  TCP connect, TLS (client checks the certificate against <server name>)
  hello\n                        ->
                                 <-     challenge <nonce>\n
  auth <name> <sig>\n            ->
                                 <-     ok\n
  ...the node protocol (section 8) from here on, both ways...
```

- **TLS.** The gate uses the daemon's server certificate (server3:
  `new.colinrozzi.com`). Theater drops a connection whose TLS handshake does
  not finish within **10 s**. The client MUST verify the certificate against
  the server name.
- **hello.** The client MUST send `hello\n` and wait for the challenge. The
  gate answers the first data it reads after TLS, whatever it says, and
  throws those bytes away, so an `auth` line sent with the hello is lost.
- **challenge.** `<nonce>` is 64 lowercase hex: the sha256 of the gate's own
  signature over `field-gate nonce <time ms><connection id>`. It only needs
  to be unguessable; a second implementation MAY use 32 random bytes as hex.
- **auth.** `<name>` is the client node's key name, and `<sig>` is its
  signature over the ASCII bytes `field-gate <nonce>` (one space, the nonce
  exactly as received). The line MUST be exactly three words and end in LF
  within **400** bytes (MAX-HELLO); longer, and the gate closes.
- The gate looks `<name>` up in `field/gate-keys`, verifies (2.4, strict),
  and connects to the node. On success it sends `ok\n`, then forwards any
  bytes that came after the auth line. On **any** failure (unknown name,
  wrong word, bad signature, the node unreachable) it closes the connection
  without a reply.

Example, the RFC 8032 test-1 key named `desktop`, nonce
`5e00...00` (62 zeros):

```
auth desktop c87eab9324b4bab2a54a162aeecc324c72aef168a027dc0194390d95a32cc6905e83b71066f68e72cb3830b5587394f7bca3ac25d185af42f5be01bf0d83fa02\n
```

The client checks that the reply begins `ok\n`; anything else is "refused".
Only the client proves itself with a key; the gate is proven by its TLS
certificate.

### 10.2 gate-keys

`field/gate-keys`: one node per line, `<name> <public key hex>`, exactly two
space-separated words. Other lines are ignored, and the first line with the
name wins. Example:

```
desktop edc937152f98317dc367d50e51dbb3eaafc2e65171936c61816b5594a910da1c
```

### 10.3 Per-connection state

`field/gate/<cid>` holds `tls` (waiting for the hello), `nonce <n>` (waiting
for auth; a partial auth line follows after an LF), `up <node cid>` (joined),
or `down <client cid>` (the node side of a join). When either side closes,
the gate closes the other. The gate clears `field/gate/` when it starts.

There is no deadline after TLS: a client that never sends hello or auth
holds its connection open.

## 11. Producers on the node (informative)

- **client.wisp**: a library for any session. It builds and signs an event
  by key name and sends `admit`, one connection per call, to
  `127.0.0.1:7800`.
- **feed.wisp** (desktop, `127.0.0.1:7802`): one line per connection, `NAME
  STATE DETAIL\n`, becomes an event in scope `agents/NAME`, kind
  `agent.STATE`, body DETAIL, signed `agents`. A line `ops NAME STATE
  DETAIL` becomes `ops/NAME`, `ops.STATE`, signed `ops`. Theater messages
  `github-events: KIND REPO REF ACTION ACTOR URL TEXT` (KIND one of `pr`,
  `review`, `comment`, `ci`) become `github/REPO`, `github.KIND.ACTION`,
  the body everything after `github-events: `, signed `github-events`.
- **chat.wisp** (`127.0.0.1:7804`): see field/SPEC-chat.md.

## 12. Deployment (informative)

| service | desktop | server3 |
|---|---|---|
| node (`serve-field.wisp`) | `127.0.0.1:7800`, name `desktop` | `127.0.0.1:7800`, name `server3` |
| gate | none | `0.0.0.0:7443` |
| peer | both directions, via `tls:new.colinrozzi.com:new.colinrozzi.com:7443:desktop` | none |
| chat | `127.0.0.1:7804` | `127.0.0.1:7804` |
| feed | `127.0.0.1:7802` | none |

`field/serve-field.wisp` at the top level is an older single-machine
version.

## 13. Conformance

A second node implementation MUST pass each of these:

1. **Encoding.** Building the example of 2.2 gives exactly those 317 bytes
   and the id `30fdea09...6148`.
2. **Signature.** With the test-1 seed, signing the id's 64 hex bytes gives
   the signature in 2.4, and that signature verifies against the author.
   Signing the 32 raw hash bytes instead MUST NOT verify.
3. **Parse refusals.** Each of these is refused, with the reason in 2.6:
   parents out of order; a parent repeated; a `link` before a `parent`; `body
   37` on a 36-byte body; a body of 16385 bytes; `time 12a`; `field 2`; a
   trailing byte after the body.
4. **Repeat.** Admitting a held event again returns its id, adds no seen
   event, and does so even if the second sig is wrong.
5. **Order.** An event whose parent is not held is refused with `missing
   parent <id>`. After the parent is admitted, the same event is admitted.
6. **Rules.** With `chat/ K1` and `chat/main K2` in the rules, K2 may write
   `chat/main` and K1 may not; K1 may write `chat/x`; nobody may write
   `github/x`. With an empty rules file, anyone may write anything.
7. **Seen chain.** After admitting E1 then E2, the chain is S1 (no parent,
   body `<E1> <scope> <kind>\n`) then S2 (parent S1), each signed by the
   node's key in scope `field/seen/<node>`. `head` answers S2. `follow - -
   -` answers `ok <n>\n<S2> 0\n<E1> <scope> <kind>\n<E2> <scope> <kind>\n`.
8. **Paging.** With 70 admitted events, `pull -` returns 64 entries and more
   1; `pull <its cursor>` returns 6 and more 0; `pull <that cursor>` returns
   cursor = the same cursor and no entries. `follow -` pages by 16.
9. **Private.** An event in `private/x` appears in no `follow` or `pull`
   page, and both cursors still move past it; `get` of its id answers
   `no such event`.
10. **Framing.** A request split across several TCP reads is answered once.
    Two requests in one read get two replies, in order. A connection
    buffering more than 20000 bytes gets `err 17\nrequest too large` and is
    closed.
11. **Watch.** A `watch` connection receives `ok 64\n<new head>` after
    another connection's successful admit, and nothing after a repeat admit.
12. **Restart.** Leaving `field/unseen/<id>` with its event file in place and
    starting the node records `<id>` in a new seen event.
13. **Peer.** Pulling A into B and then B into A copies every non-private
    event both ways, and a second round admits nothing new. A page with one
    event B refuses leaves B's cursor where it was.
14. **Gate.** A client whose auth names a key in gate-keys and signs
    `field-gate <nonce>` gets `ok\n`, then `head\n` gets the node's head.
    A wrong signature, an unknown name, or a line of 401 bytes with no LF
    gets the connection closed with no reply.

## Divergences

Where the code and DESIGN.md (or the code's own comments) disagree. The
spec states the code.

1. **Order of the event file.** DESIGN.md:213 says "the canonical text, then
   `sig <hex>`". store.wisp:9 and :101 write `sig <hex>\n` first, and every
   reader (server.wisp `get`, peer.wisp:82-85, lib/chat, chat.js) expects
   that. The spec states sig first.
2. **Missing parents.** DESIGN.md:223 says an event whose parents have not
   arrived "waits in a bounded pending set and is asked for".
   store.wisp:252-253 refuses it with `missing parent`; there is no pending
   set. The spec states refusal, so senders must send in topological order
   (a pull page already is).
3. **Parents in the same scope.** DESIGN.md:153-156 says parents must be in
   the same scope or one every holder also holds. store.wisp:236-253 checks
   only that each parent is held. The spec states no scope check.
4. **Follow by scope.** DESIGN.md:236 and :255 describe following "for a
   scope" or by scope list. store.wisp:276-279 matches one scope exactly (or
   all) and the kind by prefix. The spec states that.
5. **A wiped peer.** DESIGN.md:301-302 says a new chain is followed from its
   genesis. store.wisp:273-274 answers an unknown cursor with nothing, and
   peer.wisp:203 reads that as "idle", so a peer with a cursor into a wiped
   node's old chain waits forever until someone deletes `field/peers/<name>`.
   The spec states the code and flags it.
6. **Who authenticates.** DESIGN.md:312-313 says "each side authenticates
   with its store key". gate.wisp:81-101 checks only the client's key; the
   gate is known by its TLS certificate (peer.wisp:149). The spec states the
   one-sided key check.
7. **The hello.** gate.wisp:9 shows the client sending `hello\n`, but
   gate.wisp:107 answers any first data with the challenge and drops it. The
   spec requires clients to send `hello\n` and says the gate ignores its
   content.
8. **`private/` was only about pull** (fixed, 0063). `get` and `follow`
   served private events, so did the gate, which forwards every verb, and so
   did the follow + get fallback in peer.wisp. Now `get` and `follow` leave
   them out and the fallback is gone.
9. **Seen bodies at start.** At start, store.wisp:323-328 records every
   unseen event in one seen event with no size check, but store.wisp:170
   refuses to read a body over 16384 bytes. So a recovery of more than about
   150 events would make a seen event the walk cannot read, ending
   following there (store.wisp:291). The spec requires seen bodies <= 16384
   bytes; an implementation SHOULD split the recovery over several seen
   events.
10. **Ids as paths** (fixed, 0063). The store checked only that an id was
    64 bytes before making it a file path, and used a cursor as a path with
    no check. Now both must be 64 lowercase hex characters (`is-id` in
    store.wisp); anything else is no such event, or an empty follow.
11. **The Wisp API.** DESIGN.md:230-242 describes `experiment/lib/field.wisp`
    with `field-append`, `field-blob-put`, and others. What exists is
    `field/client.wisp` (`field-post`, `field-post-to`, `field-read`,
    `field-after`, `field-head`), and there are no blobs yet. This spec does
    not cover any library API.
