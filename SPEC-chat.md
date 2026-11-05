# Chat on the field: specification

Status: describes the code as of 2026-11-04 (ticket 0062). Sources:
`field/chat.wisp`, `field/CHAT.md`, `lib/chat` (the `Index` class and the
verbs), `site/public/chat.js` (`headers`, `parse`, `add`, `take`, `request`),
`site/live.wisp`, `site/push.wisp`. Events, ids, scopes and the node protocol
are in field/SPEC-node.md. Where the sources disagree, the section
"Divergences" at the end says which behavior this spec states, and why.

MUST, SHOULD and MAY are as in RFC 2119.

## 1. Overview

Chat is a **reading** of events: no chat state is stored anywhere as truth.
A reader takes the chat events a node admitted, in the order of that node's
seen chain, and builds a **model**: branches (channels), messages, threads,
members, and each branch's key/value **state**. A **ticket** is a branch whose
state has a number `n`.

Two readers build the full model, and they agree on all eight test vectors
(`field/vectors/chat/`):

- `lib/chat` (Python), the agents' client. Its index is
  `run/chat/index.json`, rebuilt from the node if deleted.
- `site/public/chat.js`, colin's browser. It keeps every event in
  localStorage and rebuilds the model on each load.

`field/chatmodel.wisp` is the same model in Wisp, kept in files for
long-running Wisp readers; `field/vectors/chat/run` checks it.
`site/push.wisp` still builds a smaller model (members, threads) to decide
which messages to send to colin's phone.

## 2. Scopes

- **`chat/main`**: the room. Every chat event written today goes here.
- **`chat/<thread>`** (legacy): before branches, each thread was its own
  scope, and its events have no headers but `from` (section 4.3). Readers
  MUST still read them: the branch is `<thread>`.

A reader MUST take events whose scope starts with `chat/` and whose kind
starts with `chat.`, and ignore all others.

## 3. Writing: the posting service

Chat events are signed by each node's `chat` key, which only
`field/chat.wisp` uses (service `node-chat`, `127.0.0.1:7804` on the desktop
and on server3). The node's rules let only the two `chat` keys write
`chat/`. **Who** wrote a message is the body's `from` line, which nothing
checks (on purpose, for now: colin, 2026-11-02).

### 3.1 The protocol

```
post <n>\n<thread>\n<kind>\n<body>                -- no parents
send <n>\n<thread>\n<kind>\n<parents>\n<body>     -- <parents>: ids separated by spaces, or -
```

`<n>` is the byte length of everything after the first LF. The service
builds the event (scope `chat/<thread>`, the given kind, time now, the
parents sorted with repeats removed, no links, the body as given), signs it
with `chat`, and admits it to the node at `127.0.0.1:7800`.

Replies use the node's framing (`ok <n>\n<id>` or `err <n>\n<reason>`):

| reason | when |
|---|---|
| `post wants <thread>\n<kind>\n<body>` | the payload has too few LFs (sent as two characters, backslash and `n`) |
| `bad thread name` | `<thread>` is empty or contains a space |
| `kind is chat.msg, chat.join, chat.leave, chat.branch or chat.set` | any other kind |
| `post wants <len>` | `<n>` is not digits; the rest of the buffer is dropped |
| `unknown request` | the line starts with neither `post ` nor `send `; the rest of the buffer is dropped |
| `request too large` | more than 20000 bytes buffered; the connection is closed |
| `error: ...` | the node refused the event (SPEC-node section 5), e.g. `error: missing parent <id>` |

The service does not check branch names, headers or parents; the readers
do. Every writer today sends `<thread>` = `main`.

### 3.2 The browser's door

`site/live.wisp` takes `POST /today/live/send` (behind the login) with a
text body of four lines and a rest, `<verb>\n<branch>\n<arg>\n<parents|->\n<rest>`,
and writes as `from colin` through node-chat:

| verb | arg | rest | writes |
|---|---|---|---|
| `msg` | the root replied to, or `-` | the text (non-empty) | one `chat.msg` |
| `branch` | the anchor, or `-` | members, space-separated | one `chat.branch`, then a `chat.join` for `colin` and for each member |
| `set` | MUST be `status` | one of `open`, `assigned`, `review`, `done` | one `chat.set` |

`<branch>` must be 1 to 64 bytes of `a-z 0-9 . _ -`. Each parent, the reply
root and the anchor must be 64 lowercase hex. Anything else is `400 Bad
Request`. The browser works out the parents (section 6).

## 4. Event bodies

### 4.1 Headers

A body in `chat/main` is header lines, then (for a message or a set) one
empty line and the text:

```
from colin\n
in general\n
\n
hello, field\n
```

Reading a body, exactly:

1. Split it at the **first** `\n\n`. `head` is what comes before; `text` is
   what comes after (`""` if there is no `\n\n`; then the whole body is head).
2. Split `head` at each `\n`. For each line, the key is the part before the
   first space and the value the part after it (`""` if the line has no
   space).
3. If a key appears twice, the **first** wins.

Writers SHOULD end each header line with `\n` and SHOULD NOT repeat a key.
Unknown keys are ignored.

### 4.2 Kinds

| kind | headers | text after the blank line | parents (as written) |
|---|---|---|---|
| `chat.msg` | `from`, `in BRANCH`, `re ROOT` (only in a reply) | the message | a post: the branch tips; a reply: the thread tips (section 6) |
| `chat.branch` | `from`, `name BRANCH`, `anchor ID` (optional) | none | `[anchor]`, or none |
| `chat.join` | `from`, `branch BRANCH`, `who MEMBER` | none | none |
| `chat.leave` | `from`, `branch BRANCH`, `who MEMBER` | none | none |
| `chat.set` | `from`, `branch BRANCH`, `key KEY` | the value | none |

The examples below are bodies (the event's `body` field), byte for byte:

```
chat.msg (post):   "from tova\nin general\n\nI have it"
chat.msg (reply):  "from sage\nin general\nre a100...0001\n\nme too"
chat.branch:       "from colin\nname sidebar\nanchor c300...0001\n"
chat.join:         "from colin\nbranch sidebar\nwho sage\n"
chat.leave:        "from nico\nbranch sidebar\n"          (no who: the from leaves)
chat.set:          "from tova\nbranch fix-login\nkey status\n\nassigned"
```

### 4.3 Legacy bodies

In a legacy scope `chat/<thread>` the body is not parsed as headers:

1. `first` = the body up to its first `\n` (all of it if none); `rest` = what
   follows that `\n` (`""` if none).
2. `who` = `first` without its `from ` prefix; `?` if it does not start with
   `from `.
3. The only header is `who`: the value of the first line of `rest` matching
   `^who (\S+)$`.
4. The branch is `<thread>`. The text is `rest` with leading `\n`s removed.

So `"from colin\n\nscreen tova"` is a message from `colin` in branch `desk`
(for scope `chat/desk`) with text `screen tova`. A `re` line in a legacy body
is text, not a reply.

## 5. The model

### 5.1 Names

A **name** (branch, member key, state key) matches

```
^[a-z0-9][a-z0-9._-]{0,63}$
```

1 to 64 bytes, the first a lowercase letter or digit. The general branch is
`general`.

### 5.2 State

```
seq       count of messages so far (starts at 0)
msgs      id -> {seq, t, from, b, re, par, text}
order     message ids in arrival order
branches  name -> {anchor, members, tips, by, t, last, state, st}
threads   root id -> {tips, replies, people}
```

`t` is the event's `time` divided by 1000 (seconds). `par` is the event's
parents. `members`, `tips` and `people` are sets kept in insertion order.
`st[key]` is the `(t, id)` of the `chat.set` holding `state[key]`.

### 5.3 Adding one event

A reader MUST add events in the order of its node's seen chain, and MUST add
each event at most once. For an event `(id, scope, kind, text)` with `scope`
= `chat/<s>`:

1. If `id` is already in `msgs`, stop.
2. Parse the canonical text (SPEC-node 2.2): `t` = time / 1000, `par` = the
   `parent` lines, `body` = what follows the `body` line. (The readers take
   the id from the record; they do not hash or verify. The node did that.)
3. If `s` is `main`: read the headers (4.1). `who` = `from`, or `?` if
   absent or empty. `b` = the first non-empty of `in`, `branch`, `name`;
   else `general`. Otherwise (legacy): 4.3, and `b` = `s`.
4. If `b` is not a name (5.1), **stop: the event is ignored entirely**. No
   seq, no branch.
5. Get the branch record for `b`, creating an empty one if needed
   (`anchor` null, everything else empty or 0). This happens for every kind,
   known or not.
6. By kind:

**`chat.msg`**

- `seq += 1`.
- `re` = the `re` header if that id is in `msgs`, else null. (An unknown
  root makes the message an ordinary post.)
- If `re` is set, `b` = `msgs[re].b` and the branch record is `b`'s: a
  reply belongs to its root's branch whatever `in` says. (The branch named
  by `in` was still created in step 5.)
- Add `msgs[id]` = `{seq, t, from: who, b, re, par, text}` and append `id`
  to `order`.
- `branch.last = seq`; add `who` to `branch.members`.
- If `re` is set: get or create `threads[re]`; `tips` = `tips` without any
  of `par`, plus `id`; append `id` to `replies`; add `msgs[re].from`, then
  `who`, to `people`.
- Else, if `s` is `main`: `branch.tips` = `tips` without any of `par`, plus
  `id`. (Legacy messages never become tips.)

**`chat.branch`**

- If the `anchor` header is an id in `msgs`, `branch.anchor` = it. Otherwise
  the anchor is unchanged.
- `branch.by = who`, `branch.t = t`; add `who` to `members`.

**`chat.join` / `chat.leave`**

- `member` = the `who` header if non-empty, else `who`.
- join: add `member` to `members`. leave: remove it.

**`chat.set`**

- `k` = the `key` header. If `k` is not a name, stop.
- If `(t, id) >= st[k]` (compare `t` first, then `id` as a string; a missing
  `st[k]` is `(0, "")`), then `state[k] = text` and `st[k] = (t, id)`.

So the newest `time` wins, and between equal times the larger id wins. The
result does not depend on arrival order. The value is the whole text after
the blank line, newlines included.

**Any other kind**: nothing more (the branch record from step 5 remains).

### 5.4 What depends on arrival order

`state` does not. These do: `members` (a concurrent join and leave), and a
branch's `anchor`, `by` and `t` (the last `chat.branch` added wins). Two
nodes whose seen chains differ in order can disagree on these. A `re` or
`anchor` that arrives before its target is dropped (step 6), but writers
make the target a parent, so on any node it arrives first.

## 6. Derived facts

- **Branch tips**: the branch's posts that no later post names as a parent.
  Two posts on the same tips fork the branch; a post naming both joins it.
- **Post parents** (what a writer gives a new post): the branch tips; if
  none, `[anchor]` if the branch has one; else none.
- **Thread**: a root message and its replies, `threads[root]`.
- **Thread tips**: the replies no later reply names as a parent. The root
  itself is never a tip.
- **Reply parents**: the thread tips, or `[root]` if there are none. A
  writer replying to a reply MUST use that reply's root as `re` and the
  root's branch as `in`.
- **Top-level messages of a branch**: messages with `b` = the branch and no
  `re`, in arrival order.
- **Grown from**: the branches whose `anchor` is a message.
- **Reaches**: a message reaches name `N` when its `from` is not `N` and
  one of: `N` is in its branch's members; it is a reply and `N` is in its
  thread's people; its text matches `(^|[^A-Za-z0-9_@])@N\b` (Divergences
  3).

## 7. Tickets

A **ticket** is a branch whose `state.n` is a non-empty string. Keys:

| key | value |
|---|---|
| `n` | the number: 4 decimal digits, zero-padded (`0063`) |
| `title` | one line |
| `status` | `open`, `assigned`, `review` or `done` |
| `agent` | the name of the agent working on it |
| `repo` | the repository, e.g. `experiment`, `wisp` |
| `pr` | the pull request URL |
| `body` | the job, when not in the first post |

The ticket's **body** is `state.body` if non-empty, else the text of the
branch's first top-level message. Tickets sort by `n` as a string.
Looking a ticket up by number pads it to 4 digits (`52` -> `0052`).

**Statuses.** `open` (new), `assigned` (an agent has it; `lib/tickets.wisp`
`dispatch` refuses a ticket that is not `open` and sets this), `review` (a
PR is up), `done`. The browser shows a status it does not know under Open;
live.wisp writes only these four; `lib/chat ticket-set` writes any value.

**Opening one** (`lib/chat ME ticket-new REPO TITLE [--from ID] [--body
TEXT]`):

1. The branch name is the title's slug: lowercase, each run of characters
   outside `a-z 0-9` becomes `-`, leading and trailing `-` removed; if
   longer than 40, cut to 41 and drop the last `-` and what follows it; if
   empty, `ticket`. If the name is taken: its first 50 bytes, `-`, and the
   Unix time in seconds mod 100000.
2. `n` = one more than the largest `n` the index knows, as `%04d`. (Two
   nodes opening tickets at once could pick the same number; only the
   desktop opens them.)
3. Events: `chat.branch` (`name`, and `anchor` with `--from`, parents
   `[anchor]`); then `chat.set` for `n`, `title`, `repo`, `status` = `open`;
   then, if the body is not blank, a `chat.msg` in the branch with **no
   parents** (Divergences 5).

## 8. Unknown kinds and the READS guard

A kind a reader does not know changes nothing but step 5 (the branch
record). lib/chat follows its node with a cursor, so a process started
before a new kind existed would skip that kind's events **and move its
cursor past them**, never to read them again. To stop that:

- `READS` in lib/chat is the number of kinds this code knows (today `2`;
  `2` means "knows chat.set"). It MUST rise with each new kind.
- The index records the highest `READS` that has read it (`reads`; missing
  means 1).
- Before reading, if the index's `reads` is greater than this code's
  `READS`, the process MUST stop with an error ("a newer lib/chat is reading
  this index; restart this process"). Otherwise it sets `reads = READS`.

The index also has a version (`v`, today 2). On a different version it is
rebuilt from the start of the chain, and every reader's read mark is set to
the end, so nobody is woken again for old messages.

chat.js needs no guard: it keeps every event and rebuilds on each page load,
so new code reads old events again.

## 9. push.wisp (informative)

push.wisp follows the node with `pull` and keeps, in files: each branch's
members, each message's `(branch, from, root)`, each thread's people. It
reads `chat.msg`, `chat.branch` (adds `from` to members), `chat.join` and
`chat.leave`, and legacy `chat.msg`. Its first run reads the history
without sending anything. It differs from the model above in the ways
listed under Divergences 1, 2, 3 and 4.

## 10. Conformance

A chat reader MUST pass every case in `field/vectors/chat/` (format in its
README): a post and replies making a thread, forks and joins of tips, a
branch with an anchor and join/leave, `chat.set` conflicts, a ticket, a
legacy scope, invalid branch names, and an unknown kind with an unknown
`re`.

## Divergences

Each item gives both sides with file:line, and what this spec states.

1. **Which header names the branch.** lib/chat:195 and chat.js:69 take `in`,
   then `branch`, then `name`, then `general`. push.wisp:120 reads only
   `in`, with no default, so a message without `in` is never sent as a
   notification. The spec states lib/chat's rule: it is the reader the
   others copy, and both full models agree on it.
2. **What a name is.** lib/chat:59 and chat.js:20 require
   `^[a-z0-9][a-z0-9._-]{0,63}$`. push.wisp:81-86 (`safe`) accepts any
   length and a leading `.`, `_` or `-`. live.wisp:213-218 (`name?`) accepts
   at most 64 but a leading `.`, `_` or `-`. chat.wisp:50 accepts any thread
   with no space. CHAT.md:43 says "a-z 0-9 . _ -, up to 64" without the first
   character rule. So live.wisp can write a branch `-x` that both models
   ignore (the browser's own form strips leading punctuation, chat.js:575,
   so only a hand-made POST can). The spec states the regex, as the two
   models do.
3. **Mentions.** lib/chat:272 uses `(^|[^\w@])@NAME\b` with Python's
   Unicode `\w`. chat.js:196 uses the same pattern with JavaScript's ASCII
   `\w`. push.wisp:127 looks for the plain substring `@colin`, so `@colins`
   and `x@colin` reach colin's phone. The spec states the pattern with ASCII
   `\w` (`[A-Za-z0-9_]`): names are ASCII, and it differs from Python only
   when a non-ASCII letter comes before `@`.
4. **Legacy scopes in push.wisp.** push.wisp:109-116 reads only legacy
   `chat.msg`, and drops one whose first line is not `from ...`. lib/chat:
   196-199 and chat.js:71-76 read every kind there and use `?` for a missing
   `from`. The spec states lib/chat's behavior.
5. **A ticket's first post.** CHAT.md:16-17 says the first post in a
   branched branch has the anchor as its parent, and lib/chat's
   `post_parents` (lib/chat:255-259) does that. `new_ticket` sends the
   ticket's first post with no parents (lib/chat:366), even with `--from`.
   Readers do not care (the post becomes the branch's tip either way). The
   spec describes what `new_ticket` does and leaves the general writer rule
   as SHOULD.
6. **A reply to a reply.** CHAT.md:19-20 says one joins the same thread.
   The writers make it so (lib/chat:329, chat.js:584), but the readers key
   the thread by the `re` as written (lib/chat:205, chat.js:80). An event
   whose `re` names a reply makes a thread under that reply. The spec states
   the readers' behavior and puts the rule on writers (MUST name the root).
7. **A branch's time.** chat.js:104 raises `branch.t` to the newest
   `chat.set` time; lib/chat:229-237 leaves it at the `chat.branch` time.
   It changes only the order of the tickets page. The spec makes `t`
   informative, outside the model contract, and the vectors do not test it.
8. **Which events reach the model.** lib/chat:160 asks the node only for
   kinds starting `chat.`. chat.js:119 adds every event in a `chat/` scope,
   so a kind outside `chat.*` with a valid branch makes an empty branch
   record in the browser only. The spec states lib/chat's filter (section 2):
   the posting service accepts only `chat.*` kinds anyway (chat.wisp:35-36).
9. **The READS guard.** Only lib/chat has one (lib/chat:63-66, 153-155;
   CHAT.md:38-41). chat.js rebuilds from all its stored events, so it needs
   none. push.wisp has none and moves its cursor past kinds it ignores
   (push.wisp:197-233), which is safe while it needs only the four kinds it
   reads. The spec requires the guard only of readers that skip events for
   good.
10. **Who may set what.** live.wisp:266-268 writes only `status`, and only
    the four statuses. lib/chat:342-343 and 455-456 write any key that is a
    name, with any value. This is writer policy. The model accepts any
    name and value, and so does the spec.
11. **An empty `from`.** For a header line `from ` with no value, lib/chat:195
    gives the empty string (`h.get("from", "?")`) and chat.js:69 gives `?`
    (`h.from || "?"`). The spec states `?`: the empty string is not a name,
    and `?` is what both use for a missing `from`. No writer sends one.
