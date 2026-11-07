# Documents on the field: specification

Status: ticket 0068, 2026-11-06 (ada; design agreed with tova in the chat
branch `documents-on-the-field`). A document is a chat branch with sections
that people edit, comments on a section, and the history of every edit. The
first one is the theater permissions policy (branch `theater-permissions`).

Documents are a reading of chat events (field/SPEC-chat.md), plus one new
kind, `chat.edit`. Everything is in scope `chat/main`, signed by node-chat
like any chat event. Readers: `field/docmodel.wisp` (with the vectors in
`field/vectors/doc/`), `lib/chat` (the `doc` verbs) and `site/public/chat.js`
(`/today/docs`).

MUST, SHOULD and MAY are as in RFC 2119. Names are SPEC-chat 5.1's.

## 1. Events

| what | event | headers | text |
|---|---|---|---|
| make a branch a document | `chat.set` | `from`, `branch B`, `key doc` | the title |
| its status | `chat.set` | `from`, `branch B`, `key doc-status` | `draft` or `decided` |
| edit a section | `chat.edit` | `from`, `in B`, `sec S`, `title HEADING`, `after S2` (optional) | the section's body |
| comment on a section | `chat.msg` (a post) | `from`, `in B`, `sec S` | the comment |
| resolve a comment | `chat.msg` (a reply) | `from`, `in B`, `re ROOT`, `resolve yes` or `resolve no` | why (may be empty) |

Parents:

- `chat.edit`: the section's heads (section 3); none for a new section.
- A comment: the branch tips, like any post. A resolve: the thread tips.
- `chat.set`: none.

A section's title is one line. A body is at most what the node takes (16384
bytes for the whole event body, SPEC-node 2.1); node-chat refuses a larger
one before asking the node.

Chat readers that do not know `chat.edit` ignore it (SPEC-chat 5.3, "any
other kind"); a comment and a resolve are ordinary messages to them, so they
reach people and show in the branch as usual.

## 2. The model

A reader adds each chat event, in its node's seen chain order, once, to the
chat model (SPEC-chat 5.3) and then to this one. For an event in scope
`chat/main` with headers `h`, text `text`, time `t` (milliseconds) and
parents `par`:

**`chat.edit`**

1. `who` = `h.from`, or `?` if empty. `b` = `h.in`; `s` = `h.sec`. If either
   is not a name, ignore the event.
2. Record the edit: `edits[id]` = `{t, who, b, s, title: h.title, after:
   h.after, par, text}`.
3. Section `(b, s)`, created empty if new: append `id` to its `history`;
   `heads` = `heads` without any of `par`, plus `id`.
4. If the section has no `first`, or `(t, id) < first`, then `first` = `(t,
   id)` and `place` = `h.after`. (So a section's place is the `after` of its
   earliest edit, whatever order edits arrive in.)

**`chat.msg`**, after the chat model added it as message `m`:

- If `m.re` is null and `h.sec` is a name: `m` is a comment on section `(m.b,
  h.sec)`; append its id to that section's `comments`. (The section need not
  exist yet.)
- If `m.re` is set and `h.resolve` is `yes` or `no`: if `(t, id) >=
  rst[m.re]` (missing: `(0, "")`), then `resolved[m.re]` = `h.resolve` and
  `rst[m.re]` = `(t, id)`. The newest wins, as with `chat.set`.

**`chat.set`**: nothing beyond the chat model; the document's title and
status are the branch state.

Compare `(t, id)` pairs by `t` as a number, then `id` as a string.

## 3. What a reader shows

- **Documents**: the branches whose state has a non-empty `doc`. Title =
  `state.doc`; status = `state["doc-status"]`, or `draft` if empty.
- **Heads** of a section: its edits no later edit of it names as a parent,
  newest first by `(t, id)`. The **current** edit is the first head. With
  more than one head the section is **forked**: show every head; the next
  edit names them all as parents and joins them.
- **Removed**: a section that is not forked and whose current edit has an
  empty title and an empty text. A later edit brings it back.
- **Order** of a document's sections: a section's parent is its `place` if
  that is another section of the document, the top if `place` is empty, and
  otherwise it has none. Starting from the top, list each child, newest
  `first` first, each followed by its own children (depth first). Then list
  the sections not reached (a missing or circular `place`) by name. Removed
  sections keep their place and are hidden.
- **History** of a section: its edits in arrival order; of a document, every
  edit of every section.
- **Comments** of a section: its comment ids in arrival order. A comment is
  **open** unless `resolved[id]` is `yes`. Its replies are its chat thread.

Writers: a new section's `after` SHOULD be the section it goes below (empty
for the top), and its `sec` a name not used in the document (e.g. the
title's slug). An edit of an existing section MUST name all its heads as
parents, so that it joins a fork, and SHOULD NOT repeat `after` (only the
first edit's counts). A resolve MUST be a reply to the comment itself.

## 4. Conformance

A reader MUST pass every case in `field/vectors/doc/` (format in its README;
`field/vectors/doc/run` checks docmodel.wisp, `lib/chat-vectors` lib/chat).
