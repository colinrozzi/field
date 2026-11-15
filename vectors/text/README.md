# Text test vectors

Each file is one case for a text reader or writer (field/SPEC-text.md). `make`
writes them from the cases in it, with a reference reader and writer that
follow the spec's rules on a plain character tree; edit the cases there, not
the JSON. Run it only under a memory cap (the shared daemon lives in the same
cgroup until ticket 0128):

    systemd-run --user --scope -p MemoryMax=4G field/vectors/text/make

## Events

`events` is `[[id, scope, kind, file_text], ...]`, the chat vectors' format
(../chat/README.md): ids are made up, signatures are zeros, the author is a
real key, and each text is otherwise canonical. Every event is `doc.ops` in
`doc/plan`. A reader takes the parents from the file text's `parent` lines
and the ops from its body.

## Reader cases (`orders`)

`orders` is a list of arrival orders, each a list of indices into `events`.
Every order respects parents, as a node's seen chain does. A case with a few
events lists all such orders; one with many lists the array order and up to
119 others; `big` lists one. For **each** order, start an empty model, apply
the events in that order, and check `expect`:

| key | meaning |
|---|---|
| `text` | the document's text |
| `ids` | the visible characters' ids in order, `E:k` |
| `invalid` | the ids of the events the reader ignored, sorted |
| `cursor` | `{id: offset}` for every character, deleted ones too: the offset in `text` just after it (the number of visible characters up to and including it, in document order). A cursor held as "after character X" shows there |
| `length`, `sha256`, `start`, `end` | `big` only, instead of `text`, `ids` and `cursor`: the text's length in code points, the sha256 of its UTF-8, its first and last 80 code points |

## Writer cases (`writes`)

`events` is the starting state, in array order. Each entry of `writes` is
one edit made from that state alone: `{id, from, pos, delete, insert}`
deletes `delete` code points at visible offset `pos`, then inserts `insert`
there, as one event with id `id` (SPEC-text 4). `expect`:

| key | meaning |
|---|---|
| `text` | the starting text |
| `ops` | for each write, its op lines exactly |
| `after` | for each write, the text after it alone |
| `merged` | the text after the state plus every write (each write's parents are the state's heads, so the writes are concurrent; any order gives this) |

Compare everything exactly, lists in order.

## Cases

| file | shows |
|---|---|
| 01 typing | a run, and the next as the right child of its last character |
| 02 split | typing inside a run: a left child of the next character |
| 03 deletes | a delete across two events (two `d` lines), typing next to a tombstone |
| 04 concurrent-same-spot | two runs at one spot come out whole, by event id |
| 05 concurrent-ends | concurrent appends and prepends |
| 06 concurrent-delete | text typed inside concurrently deleted text survives; overlapping deletes |
| 07 own-refs | `@:k` across several `i` lines of one event, a delete of its own text |
| 08 sibling-order | siblings by event id, then `k` as a number (9 before 10) |
| 09 code-points | offsets in code points; the `\n` and `\\` escapes |
| 10 backwards | typing at the start each time: a chain of left children |
| 11 invalid | thirteen kinds of bad event, an event built on one, blank op lines, no ops |
| 12 big | 20,000 runs in 34 events; a left chain thousands deep: walks must loop, not recurse. A runner reports how long it took |
| 13–21 w-* | the writer: empty document, end, middle, start, after tombstones, a delete across two events, replace, two concurrent writers at one spot, code points |

## Status

`make`'s reference passes every case by construction, and checks that each
listed order gives the same result (2026-11-15). The Wisp reader (ticket
0123) and the JS reader (0124) are built against these.
