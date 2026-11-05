# field: one network of content-addressed events

Status: design draft, 2026-11-01 (tova, with colin); built since, see "As
built" and "Running" below.

Words (colin, 2026-11-03, ticket 0057): a **node** holds events, publishes
the stream of what it sees, and answers `get`. The **field** is what many
connected nodes make. Each machine runs one node: services `node` (the
store), `node-peer`, `node-chat`, and `node-feed` or `node-gate`. Below,
"store" means a node's event store. Names inside signed events (kind
`field.seen`, scope `field/seen/`) keep the old word; they are history.

## The idea

Every system we build ends up keeping a log of events and telling someone when a
new one arrives. Theater chains, the session inbox (ticket 0018),
github-events, docs-deployer, agent-to-agent messages, the mail design, and
the chain recorder all do this, each with its own log, its own subscription
mechanism, and its own answer to "what have I already seen?".

The **field** is the one place those events live. An event is content
addressed, signed by its author, and names the events it follows. The field
stores events, links them, moves them between machines, and tells interested
actors when new ones arrive. **Everything else is a reading**: a mail inbox, a
chat room, an agent's conversation, a dashboard. Each reading is a function of
the events it can see, and can be rebuilt from them.

This is the ntwk axiom (`~/work/ntwk/WHITEPAPER.md`) taken at its word:
"there is only one operation: append an event into the causal past." It
differs from ntwk in one way: the field itself requires no lattice and no
`apply`. Most events (a mail arrived, a PR merged, an agent replied) need to be
stored, linked and noticed, not folded into a converged state. ntwk-style
networks, with a lattice state and an `apply`, are one kind of reading on top,
for the things that need converged state (chat rooms, membership, grants).

## What we keep, and what we leave behind

From mesh (`~/work/actors/mesh`), chat (`~/work/actors/chat`), mesh-exploring
and ntwk:

| Keep | Leave behind |
|---|---|
| Content-addressed events with parent links; grafting a head is witnessing it | Membership and finality inside the substrate |
| ed25519 identity: an author is a key | One composite actor (system ⊕ node ⊕ SM) with a ~6 s init |
| Ids from hashes, never shared counters | Catch-up that walks back one layer per round trip |
| "Recovery is re-projection, not persistence"; never store folded state as truth | Whole-state blobs on every write |
| "Consumers read what the store computes, never re-derive it" | Order-dependent rejection (the Oct 4 wedge) |
| "Subscribe before you author" | Live streams nobody trusted, so every client polled |
| "Handlers return fast; nothing slow sits on the op loop" | Plaintext, open-read ports |
| Conflicts surfaced, not resolved; lattices for anything that must converge | Global membership; peer discovery; NAT traversal (not yet needed) |

## Events

```
event {
  author   ed25519 public key
  scope    which part of the field this belongs to, e.g. colin/agents
  kind     what it is, e.g. agent.say, mail.received, github.pr.merged
  time     the author's clock, ms; a claim, never used for order
  parents  ids of field events this one follows (same scope, see Scopes)
  links    typed references to things outside the field (see Links)
  body     UTF-8 text, at most 16 KiB; its format is the kind's business
}
```

**Canonical encoding** is text, so that Wisp can build it, read it and print it
without a codec, and so it never carries bytes that aren't UTF-8 (a non-UTF-8
string returned to the host kills a Wisp session). One field per line, in this
order, parents and links sorted, body last, prefixed by its length in bytes:

```
field 1
author 3b6a27bc...e1
scope colin/agents
kind agent.say
time 1793541600000
parent 0f2c...
parent 9a71...
link blob 5d1e... 48213 text/plain
link theater-chain 7c4f... 1032
body 22
nico: rebase on main
```

- **id** = sha256 of the canonical encoding, as 64 hex characters.
- **sig** = ed25519 over the id's 64 hex characters. It travels with the event but is not part of
  the id. ed25519 signatures are deterministic, so one author produces one id
  for one event.
- Order is ancestry and nothing else. Two events are concurrent when neither is
  an ancestor of the other. Readings that want a total order use
  `topo-sort` with an id tiebreak, which may change the order they show but
  never the state they compute.

### Blobs

Anything large or binary is a **blob**: content addressed by sha256 and stored
apart from events. An event links it as `link blob <hash> <size> <type>`. Blobs
can be fetched lazily and **dropped** under a scope's retention policy. The
event stays, and its hash still proves what the blob was. That is how the
chain recorder already treats payloads, and it answers ntwk's open question
about retention: events are small and kept forever; content can go.

### Links

`parents` are field events only. Everything else content-addressed is a typed
**link**, which the store does not need to fetch, validate or understand:

- `link blob <sha256> <size> <type>`: content (above).
- `link theater-chain <sha1> <count>`: a Theater actor's chain head. Theater
  hashes chains with SHA-1 (`theater-chain/src/event.rs`), so a chain head is a
  different kind of name from an event id. An event linking a head
  *witnesses* that chain as of that point, without copying it. The chain
  can be fetched later from the actor or the recorder.
- `link git <repo> <commit>`, `link event <id>` across scopes, and so on, as
  needed.

Keeping these out of `parents` keeps closure honest: an event's ancestry is
always in the field, so any store holding it can check it.

## Authors and keys

An author is an ed25519 key. Every producer has one: each service session
(github-events, mail), the agent bridge, each browser colin logs in from, and
colin's own root key.

- **Keys never enter Wisp.** The daemon holds them in a key directory and Wisp
  asks it to sign by key name: `(sign "github-events" id)`. A compromised
  session can sign as its own key, but cannot read or copy it.
- **Browser keys** are WebCrypto ed25519 keys created non-extractable in the
  browser. colin's root key grants a browser key by appending a `key.grant`
  event. The key signs that browser's `agent.say` events, so server3 can
  carry them but can never forge them.
- **Who may append to a scope**:
  - **v1:** a per-scope list of keys in each store's config. It is a local
    admission rule, the same for every arrival order, so no order-dependent
    rejection.
  - **Later:** `key.grant` and `key.revoke` events read as an ntwk lattice
    (grants only accumulate; a revocation is a fact that is read as
    "excluded from here on"). An event is admitted when a grant for its author
    is in its own ancestry. That rule is closed over ancestry, so every store
    decides the same.

## Scopes

Every event belongs to exactly one **scope**: `colin/mail`, `colin/agents`,
`colin/private`, `public/site`, `infra/github`, and so on. A scope decides:

- **where its events live:** which stores hold and sync it (colin/mail on
  server3 and the laptop; infra/github only on the laptop);
- **who may append:** the key list above;
- **retention:** how long its blobs are kept.

Parents must be in the same scope, or in a scope every holder of this one also
holds (`public/*`). Across other scopes, use `link event`: it names the other
event without making it part of this one's ancestry, so a store that doesn't
hold that scope can still check this event. ntwk asks "who holds which
events?"; scopes are the answer.

## The store

One **field store** per machine: a Wisp service session (`field`, from the
daemon's boot list), so it restarts with the daemon and is one of the actors
in the field it serves. Each store has its own key, and is an author like any
other.

**Admission** is the whole substrate. An event is admitted when:

1. its id matches its encoding;
2. its signature verifies;
3. its author may append to its scope;
4. every parent is already admitted.

### The store's log is a chain of `seen` events

A store records what it admitted **as events**, not in a private log file. It
authors one chain, in the scope `field/seen/<store>`:

```
kind field.seen
parent <the previous seen event in this chain>
body   one line per admitted event: "<id> <scope> <kind>"
```

Every flush of newly admitted events (one, or a burst of fifty) becomes one
`seen` event. That chain is the store's log:

- **It is in topological order.** Rule 4 means an event's parents appear in
  the chain no later than the event itself.
- **Cursors are hashes.** "I've read server3's chain up to `9a71…`" stays
  true forever. A wiped store starts a new chain from a new
  genesis, and anyone following it can see that it did.
- **It is signed provenance.** Whether server3 has an event is answered by
  whether its id is in server3's chain. The agents UI's sent / synced /
  delivered ticks come from this, with no extra protocol.
- **It is one chain for every scope, for now (deliberately permissive).**
  Followers filter the lines by scope. The cost is that anyone following a
  store learns the ids, scopes and kinds of everything it holds, though not
  the events themselves. That's fine while both stores are colin's. Tighten
  it when a store follows someone else's: one chain per (store, scope), so
  following colin/agents never shows that colin/mail exists.
- **It witnesses.** Mesh made every content event graft the heads its author
  had seen, which made events wide. Here the `seen` chains do the witnessing,
  so content events keep only their meaningful parents (the message this one
  replies to).

**`seen` events are never themselves recorded in a `seen` chain.** Store
chains are the meta level. They record content events, never each other,
so a `seen` can't cause another `seen`.

On disk, under the REPL filesystem:

```
field/events/ab/cdef...     one file per event: the canonical text, then "sig <hex>"
field/blobs/5d/1e...        one file per blob
field/seen-head             the newest seen event
field/seen-first            the first
field/seen-next/<id>        the seen event after <id> (a chain links backwards;
                            following walks forwards, in pages)
field/unseen/<id>           admitted but not yet recorded; a crash leaves
                            these, and start records them
```

An event whose parents haven't arrived waits in a bounded pending set and is
asked for. The store keeps no state in memory that the files can't rebuild, so
its heap stays flat however large the field grows (see
`docs/proposals/WISP-RETENTION.md`).

## Using it from Wisp

`experiment/lib/field.wisp`, over a TCP line protocol to the local store
(127.0.0.1:7800):

```
(field-append scope kind body parents links)  ; parents: only what the event means
(field-get id)                            ; -> the event, or (none)
(field-follow after [scope [kind-prefix]]) ; this store's seen chain after hash `after`
                                          ;   ("" = from the start), one page at a time:
                                          ;   -> (cursor entries more)
(field-blob-put text) / (field-blob-get hash)
(field-subscribe scope kind-prefix)       ; the store messages this session per new seen event:
                                          ;   "field: seen <seen-id>"
```

A subscriber keeps its own cursor (the last `seen` event it read), as the
session inbox does. When woken it calls `field-follow`, so a lost notice costs
nothing. **Subscribe
before you author.** The subscription is a hint; the log is the truth.

## Sync between stores

Sync is following, the same as local subscription. A store, a reading and the
website all do the same thing: follow a store's `seen` chain for a scope from a
hash, and fetch the ids they want. The wire needs two requests:

- `follow after <hash> [scopes]`: stream the next `seen` events of the
  store's chain (with only the lines in those scopes), then keep sending new
  ones as they're authored.
- `get <id>`: one event or blob.

As built (2026-11-03): `follow` answers one page and does not stream; instead
a peer also sends `watch` on a second connection, and the store answers it
once more, unasked, each time it sees a new event ("ok <len>\n<new head>").
The peer pulls on each of those, so an event crosses in well under a second;
a 60 s tick pulls too and re-opens the watch if it closed. Both directions run
through `field/tunnel` (SSH). Since 0051 (below) there is no tunnel.

Since ticket 0054 (2026-11-03) a peer pulls rather than follows: `pull
<cursor>` answers up to 64 seen events with the events themselves inline, so
there is one round trip per page instead of two per event. The peer pulls up
to 8 pages per call, and while the store says there is more, it calls again
50 ms later (a `catchup` timer). Each store publishes everything except scopes
under `private/`; each peer keeps what its `WANTS` list names (empty: all).
Measured: server3's whole history (about 1,600 event files) in 6 s from an
empty cursor, and a burst of 50 events on the desktop reached server3 0.4 s
after the last. Before, a 400-event backlog took about 15 minutes. Events
sealed to an audience, with announce and fetch separated, is ticket 0056.

Since ticket 0051 (2026-11-03) there is no SSH tunnel. server3's store stays
on loopback behind `field/gate.wisp` (service `node-gate`), which listens on
:7443 with TLS (the new.colinrozzi.com certificate), waits for the client's
hello, sends a challenge, and joins the client to the store only if it signs
`field-gate <nonce>` with a key listed in `field/gate-keys`. A silent client
is dropped by Theater's 10 s handshake deadline. server3 can't reach the
desktop, so the desktop's `node-peer` runs both directions through the gate
(`field/desktop/serve-peer.wisp`): `server3` pulls server3's events in,
`server3-push` pulls ours out, each woken by a watch. Peer addresses of the
form `tls:<server name>:<host:port>:<key>` dial through a gate (`peer-dial`).
Measured over the internet: 0.3 s desktop to server3, 0.1 s back.

When store A follows B's chain, each `seen` event from B names ids. A fetches the ones it lacks and wants, admits them (B's chain is in
topological order, so parents come first), and records them in **its own**
`seen` chain. B, following A, sees ids it already holds and fetches nothing,
so echoes stop after one hop.

- **Pulling is optional.** A store can follow a chain and know which ids
  exist without holding them, fetching on demand. The website can know every
  agent reply exists but pull only the ones it shows. Blobs are almost always
  fetched lazily.
- **Catching up is one stream**, however deep the history: follow from your
  last cursor.
- **A new chain** (a peer was wiped) means follow it from its genesis; ids
  you already hold cost nothing.

**A store only ever serves.** Following is a separate `peer` session per
remote store. Actors are single threaded, so two stores that each blocked on a
request to the other would deadlock. A peer session can block on the network
and hold up nothing but itself; it talks to the remote store and the local
store as a client of each.

Transport is TCP between two known stores. For v1 that means the laptop and
server3, over the ssh tunnel the laptop opens, so nothing new listens on the
internet. Each side authenticates with its store key (challenge and
signature, as mesh did). No discovery, no gossip, no NAT traversal until a
third place needs it.

**Configuration in the field (later).** Which stores follow which chains, and
which store holds which scope, can be events in a `field/peers` scope. Each
store's routing is then its reading of them. The base case is a config list
of chains to follow; everything above it is events.

## Readings

A reading subscribes to some scopes and kinds and computes something:

- **an agent's conversation:** `agent.say` and `agent.reply` in colin/agents,
  ordered by ancestry;
- **a mail inbox:** `mail.received` plus `mail.read` and `mail.filed` events;
- **a chat room:** an ntwk network (the old chat-sm state as a lattice) folded
  over its events;
- **the github feed:** what github-events sends today, as `github.*` events.

Rules, from chat's lessons:

- **A reading never writes its state back as truth.** It may cache, but it
  can always be rebuilt from the log.
- **A reading changes the world only by appending events.** Marking mail read
  is a `mail.read` event, not a flag in a file.
- **Validity a reading imposes is a reading too.** An event a reading rejects
  is still in the field. The reading shows it as invalid, the same way for
  every arrival order.

## First application: the agents, from the website

1. **The agent hooks** (`lib/agent-hook`) append `agent.status` events
   (working, idle, waiting plus its prompt) to colin/agents. A Stop hook appends
   `agent.reply` with the agent's last message (long ones as a blob).
2. **server3's store follows** the laptop's colin/agents chain, and the
   laptop's follows server3's.
3. **The website** (the private session, behind the login plus a second factor)
   reads colin/agents from server3's store: a list of agents with their status,
   and each agent's conversation.
4. **Sending:** the browser signs an `agent.say` event with its granted key and
   posts it to the site, which appends it to server3's store. It syncs to the
   laptop.
5. **The bridge** (a laptop session subscribed to `agent.say`) checks that the
   author is a granted browser key and the scope is right, types the text into
   that agent (`agent send`), and appends `agent.delivered` with the say's id as
   a parent.

A compromised server3 can read colin/agents (it holds it) but cannot make an
agent do anything: it has no browser key, and the bridge acts only on events
signed by one. The tunnel carries field sync and nothing else, with no remote
procedure calls into the laptop.

## Not doing (yet)

- **Consensus or finality.** Nothing in the substrate decides "exactly one".
  When something needs that, it is a reading with its own rule, layered on top
  (ntwk §8).
- **Byzantine tolerance.** Authors may fork (two events with the same parent).
  We detect and show it; we don't punish it.
- **Encryption at rest, or of blobs per scope.** Scopes control where events
  go; that is the privacy boundary for now.
- **Compaction of events.** Events are small and kept forever; blobs carry
  retention.
- **Peer discovery or more than two stores.**

## Milestones

1. **Hashing and signing in Wisp** (wisp ticket): `(sha256 text)`, plus
   `(sign keyname text)` and `(verify pubkey sig text)` with keys held by the
   daemon in a key directory (`[keys] dir = ...` in config.toml). Small, like
   0041.
2. **The store and lib/field.wisp** on the local daemon, with tests: append,
   admission rules, `seen` chains, restart and rebuild, follow, subscriptions.
3. **Real producers:** github-events and the agent hooks append to the field.
   Their current outputs keep working alongside it.
4. **Sync** between the laptop and server3 over the tunnel: each follows the
   other's `seen` chains.
5. **The agents pages** on the website, read-only, plus TOTP on the login.
6. **Browser keys and agent.say**, and the bridge.

Later: mail as `mail.received` events (sage's M2), chat rooms as ntwk
readings, Theater chain witnesses from the recorder, and a field browser that
shows any scope as a DAG (chat-canvas-v2 already draws one).

## Open questions

- **Body format.** UTF-8 text with the format per kind is the minimum. Do we
  want a convention (key: value lines? one s-expression?) so generic tools
  can show any event?
- **Default parents.** Since the `seen` chains witness, a content event's
  parents can be only what it means: the author's previous event in the scope
  (if the kind is a sequence) and what it replies to. Settled, unless
  something needs more.
- **`seen` overhead.** One extra event per flush per store. Fine for colin's
  traffic. If a scope gets busy, flush on a timer (every second) instead of
  per admission.
- **The store in Wisp or Granite.** Wisp first, to find the shape. Granite
  when it should last (the repo's own split), most likely after milestone 4.
- **Root key custody.** On the laptop with a passphrase, or a hardware key?

## Running (2026-11-01)

Two stores are live: `laptop` (shared daemon) and `server3`
(boot-list services, `field/server3/`). The desktop's peer joins them through
server3's gate (see "As built" above; until 0051, an SSH tunnel and a peer
polling on each side).
Producers so far: `node-feed` (github-events, agent-hook).
