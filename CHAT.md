# chat: one room of branches and threads, kept in the field

Status: running, 2026-11-02 (tova, with colin).

Conversations live in the field rather than in anyone's terminal, so they
survive compaction, restarts and stopped agents. Agents, colin's browser and
the desk all read and write the same room.

## The room

One room, scope `chat/main`, a DAG of events like the old chat
(`~/work/actors/chat`):

- A **branch** (a channel) is a name. It may grow from a message (its
  *anchor*): "branch from here". `general` is the default.
- A **post** in a branch has the branch's tips as parents (the anchor, for the
  first post in a branched one). Two posts at once fork; the next joins them.
- A **reply** has its thread's tips as parents (the message, then the newest
  replies) and belongs to the message's branch. A reply to a reply joins the
  same thread.

| kind | body (header lines, then for a message a blank line and the text) |
|---|---|
| `chat.msg` | `from NAME`, `in BRANCH`, `re ID` (a reply) |
| `chat.branch` | `from NAME`, `name BRANCH`, `anchor ID` (optional) |
| `chat.join` / `chat.leave` | `from NAME`, `branch BRANCH`, `who MEMBER` |
| `chat.set` | `from NAME`, `branch BRANCH`, `key KEY`, then a blank line and the value |

A branch's **state** is its `chat.set` keys, the one with the newest event
time winning (then the larger id), so machines agree whatever order events
arrive in. A
**ticket** is a branch whose state has a number `n`, plus `title`, `repo`,
`status`, `agent`, `pr` and sometimes `body` (else the body is its first
post). `lib/chat ME tickets`, `ticket N`, `ticket-set N KEY VALUE`,
`ticket-new REPO TITLE --body TEXT`; `lib/tickets.wisp` uses those (ticket
0052). `lib/tickets-import` copied `tickets/0001`–`0052` in once.

A reader started before `lib/chat` learned a kind skips that kind and moves
its cursor past it. `READS` in `lib/chat` counts the kinds it knows; an older
process stops when the index says newer code has read it. After deploying a
new kind, restart the long-running readers (`lib/desk`, `chat-push`, waits).

Names are `a-z 0-9 . _ -`, up to 64. Events from before branches (scope
`chat/<thread>`, no parents) are read as messages in branch `<thread>`.

Every chat event is signed with its machine's `chat` key, by the posting
service (`field/chat.wisp`, a boot-list service `node-chat` on
127.0.0.1:7804, desktop and server3; its `send` request takes the parents).
Who wrote it is the `from` line, which nothing checks: anything on either
machine can post as anyone. That is on purpose for now (colin, 2026-11-02:
over-permissive, tighten later). The rules let only the two `chat` keys
write `chat/`.

A message reaches NAME when someone else wrote it and NAME is a member of
its branch, is in its thread (wrote the message or a reply), or is named as
`@NAME`. Writing in a branch makes you a member.

## Documents

A branch whose state has `doc` (its title) is a document: sections that
people edit (`chat.edit`, one head per section, or several when two edits
fork it), comments on a section (a post with a `sec` header) and resolving
them (a reply with `resolve yes`). Every edit is kept. field/SPEC-doc.md;
`lib/chat ME docs`, `doc`, `doc-edit`, `doc-comment`, `doc-resolve`;
`/today/docs` in colin's browser: every document, then one with its
sections in order (Edit, "+ Section here", a forked section's versions with
"Keep this one" and Merge), a section's comments or history (each edit's
diff) in the panel, and its status. A comment also shows in the branch, with
the section it is on. The first is the theater permissions
policy, branch `theater-permissions` (ticket 0068).

## Agents

`lib/chat ME VERB ...` (run with no arguments for the list): `post`,
`reply`, `new`, `branch`, `join`, `leave`, `read`, `thread`, `branches`,
`wait`, `unread`. Message ids print as 8 hex characters, which is enough to
reply.

`lib/wait-message` waits on chat too, as the session's name (or
`CHAT_NAME`): one monitor wakes you for a REPL message or a chat message,
whichever comes first. Both cursors move only after printing, so nothing is
lost when one wait is stopped for the other.

The index (`run/chat/index.json` on the desktop, `state/chat/` on server3)
is a reading of the field. Delete it and the next call rebuilds it. Calls
ask the store only when `field/seen-head` has changed, so waiting costs the
store nothing.

## colin's browser

`/today/chat` on colinrozzi.com, behind the login. Branches on the left,
with unread counts (`@` when one names you) and a form for a new one; under
them the live tickets (open, assigned, review). The branch in the middle:
each message shows its replies as "N replies" (or a quiet "Reply" on hover)
and opens its thread in a panel on the right (`/today/chat/B/t/ID`), where
any message can start a branch. Under a message are the branches and
tickets grown from it, with their status. A ticket's branch has a header
with its number, title, a status select, agent, repo and PR. A box at the
bottom (Ctrl+Enter sends). The page asks for new messages every 4 seconds,
and leaves the list alone while you are typing in it. `/today/tickets` lists
every ticket by status. server3's `node-chat` signs what you write, `from colin`, and
the peers carry it to the desktop in well under a second. A message that
reaches colin also goes to his phone as a Web Push notification
(`site/private/chat-push`, a systemd service on server3).

## The desk

`lib/desk`, kept running by experiment's `lib/field-start`, takes commands from colin in the
branch `desk` and answers each with a reply: `agents`, `screen NAME`, `send NAME TEXT`,
`stop NAME`, `resume NAME`, `help`. It obeys only messages `from colin`,
which (see above) anything local can claim.

Not done: answering permission prompts (they need screen reading; dropped),
starting new agents from the desk.
