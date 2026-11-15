# Live text on the field: specification

Status: ticket 0122, 2026-11-15 (ada). Step 1 of live documents (design:
document `live-docs`, decided by colin 2026-11-15; rules agreed with tova,
ivo and remy in the chat branch `live-docs-1-spec-text-md-and-test`).

A document's text is a sequence CRDT, **Fugue** (Weidner and Kleppmann,
"The Art of the Fugue", 2023), whose operations are field events. Every
reader that applies the same events, in any order a node may deliver them,
gets the same text. Two people typing at one spot at once get their runs one
after the other, never interleaved letter by letter.

Readers: the Wisp model (ticket 0123) and the JS model (0124). Both MUST
pass `field/vectors/text/` (section 6). MUST, SHOULD and MAY are as in RFC
2119. Names are SPEC-chat 5.1's.

## 1. Events

| field | value |
|---|---|
| kind | `doc.ops` |
| scope | `doc/D`, the document's scope (SPEC-group 6) |
| parent | the `doc.ops` events in `doc/D` that the writer had seen and no other seen one names as a parent (its heads); none for the first |
| body | header lines, an empty line, then one op per line |

Headers: `from WHO`, the writer's name (chat's `from`; a reader shows `?` if
it is missing). Readers ignore other headers.

A writer sends one event per **burst** of typing, flushed after about 800 ms
without a keystroke or at about 2 KB of op text, and never more than the node
takes (16384 bytes of body, SPEC-node 2.1). A larger paste is several events,
each naming the one before as a parent.

Other kinds in `doc/D` (`doc.set`, `doc.edit`) are not text and are ignored
here.

## 2. Characters and ids

A **character** is one Unicode code point (not a UTF-16 unit, not a byte).
All offsets and counts here are in code points.

Each event inserts some text: the text of its `i` lines, joined in line
order. Character `k` of that text (from 0) has the id **`E:k`**, where `E`
is the event id (64 lowercase hex). Ids never change and are never reused.

A reference in an op is one of:

- `E:k`: character `k` of event `E`;
- `@:k`: character `k` of **this** event's text (a writer does not know its
  own event id until the event is made);
- `^`: the root, the start of the document. It is not a character.

`k` is a decimal number without leading zeros (`0`, `7`, `12`).

The document is a tree. The root is `^`; every character has a parent (a
character or `^`) and a side, `L` or `R`. A node's left children and its
right children are each ordered by id: by `E` as a string, then by `k` as a
number. **The text** is an in-order walk of the tree: a node's left children
(each with its subtree, in order), then the node, then its right children
(each with its subtree), leaving out the root and deleted characters.
Deleted characters stay in the tree (tombstones).

## 3. Ops and how a reader applies them

**`i P SIDE TEXT`**: insert. `P` is a reference, `SIDE` is `L` or `R`, and
`TEXT` is everything after the third space, unescaped (below). It MUST NOT be
empty. If `TEXT` has `n` characters with ids `x0 .. x(n-1)`, then `x0` is a
`SIDE` child of `P`, and each `x(j+1)` is the right child of `xj`. (So a run
of typing is a chain, and a reader MAY store it as one run, splitting it
when something is inserted inside: the result MUST be the same as for the
character tree.)

**`d P N`**: delete. `P` is `E:k` or `@:k`; `N` is a decimal number of at
least 1, without leading zeros. Characters `E:k` to `E:(k+N-1)`, all inserted
by the one event `E`, are deleted. Deleting a deleted character changes
nothing.

**Escapes in `TEXT`**: `\n` is a newline and `\\` a backslash. A backslash
followed by anything else, or ending the line, makes the event invalid. Every
other character stands for itself (spaces too, leading or trailing).

**Lines.** The ops are the lines after the first empty line of the body,
split on `\n`. Empty lines are skipped. Fields are separated by exactly one
space. Any other line is malformed. An event with no ops is valid and
changes nothing.

**Applying an event.** For event `E` arriving in a node's seen chain order:

1. If `E` was applied or ignored before, stop.
2. Check every op, in line order. `count` = the characters inserted by
   the earlier `i` lines of `E`. An event is **invalid** if any line is
   malformed or empty-text or has a bad escape, or if any reference fails:
   - `E2:k` with `E2` an event that this model has not applied (unknown,
     ignored, or `E` itself), or `k` not less than the length of `E2`'s
     inserted text;
   - `@:k` with `k` not less than `count` (an op may name only text that
     earlier lines of the same event inserted);
   - a `d` whose last character (`k+N-1`) fails the same test;
   - `d ^ N`.
3. If `E` is invalid, **ignore the whole event**: no op of it is applied,
   and any later event that names one of its characters is invalid too.
4. Otherwise apply its ops in line order.

The node delivers every event after its parents (SPEC-node 5, step 6), so
the reader never waits for a reference. For that to hold, a writer MUST make
every event it references an ancestor of its event (naming its heads as
parents does). A writer that breaks this can make two readers disagree: one
may hold the referenced event and the other not yet.

## 4. Writing

A writer edits its own view and sends the ops. To insert text at visible
offset `pos`:

1. `L` = the visible character just before `pos`, or `^` if `pos` is 0.
2. `R` = the character right after `L` in the walk of section 2 **with
   tombstones included**, if any.
3. If `L` has no right children: `i L R TEXT`. Otherwise: `i R L TEXT`
   (then `R` is in `L`'s right subtree and has no left children).

To delete the `n` visible characters from `pos`: group them, in text order,
into stretches of consecutive ids of one event (`E:k`, `E:(k+1)`, ...); one
`d E:k N` per stretch. A replace is the `d` lines, then the `i` line, with
`L` taken after the delete (it is the same character). A reference to text
the same event inserted is written `@:k`.

Readers accept any parent and side; these rules decide only where an
insert goes among concurrent ones. A writer SHOULD follow them so that every
implementation types the same way, and the writer vectors check that it
does.

**Cursors and comments** hold character ids, not offsets: "after character
X" (or the start). When `X` is deleted the position is just after the
nearest visible character before it in the walk. The `cursor` key in the vectors gives that offset for
every character.

## 5. Later: snapshots

A long document will be opened from a `doc.snap` event: the model at some
point, as a blob link, made by the `docs` service. A snapshot will be a
cache, never the truth: the `doc.ops` events are, and a bad snapshot is
thrown away and rebuilt. Its format and how a reader finds the events after
it are left to a later ticket, once real documents show their sizes. Until
then a reader applies every `doc.ops` event of the document.

## 6. Conformance

A reader MUST pass every reader case in `field/vectors/text/`, in every
listed order, and a writer every writer case (format in its README). The
`big` case (20,000 runs, a chain of left children 10,007 characters deep)
checks that walks of the tree and of runs are loops, never recursion down
the tree; a runner reports its time.
