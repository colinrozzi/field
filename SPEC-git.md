# Git pushes on the field: specification

Status: ticket 0096, 2026-11-14 (ada; plan agreed with tova in the ticket's
branch). Step 1 of 0095, self-hosted git: experiment's repo lives on
server3, and GitHub becomes a mirror.

## 1. The event

A repo that a node holds records each ref that moves as one `git.push`
event in scope `git/<repo>`, signed by that node's own key (`field/node`).
The node is vouching that the ref moved in a repo it holds. Body:

```
from <pusher>
repo <repo>
ref <full ref name, e.g. refs/heads/git-trial/a>
old <40 hex, or 40 zeros for a new ref>
new <40 hex, or 40 zeros for a deleted ref>
```

`from` is the label of the ssh key that pushed (`git-serve NAME` on
server3), not a field identity: today there is one key, `desktop`. Only ref
names and hashes go in: no commit messages, authors or contents.

Rules: `git/ <server3's node key>`. No other key may write `git/`.

## 2. How it is written

On server3, the repo's `post-receive` hook sends one `post` per ref to
node-chat on 127.0.0.1:7804 (field/chat.wisp), kind `git.push`, thread
`git/<repo>`. node-chat signs it with the node key, like `id.*`. The hook
gives up after 2 seconds and never fails the push: a push whose event was
lost is still a push, and the mirror catches up on the next one.

Any local user on server3 who can reach :7804 could post a `git.push`, as
with chat: the trust is the machine's (field/chat.wisp, top).

## 3. Who reads it

The desktop's mirror (`lib/git-mirror` in experiment) watches `git/` and,
for each event, fetches from server3 and pushes to GitHub, never forced and
never deleting, so GitHub keeps every commit. The GitHub credential stays on
the desktop. Later steps (PRs, checks) read the same events.

## 4. Later: through the gate

Today git reaches server3 over ssh, as a `git` user whose login shell is
git-shell and whose one key runs a forced command. The field gate (0051,
SPEC-node.md section 10) already admits a peer by TLS plus a signed
challenge from a node key. A later step could add a git verb to the gate
that pipes `git-receive-pack`/`git-upload-pack` over that authenticated
stream, with the pusher being the key that signed the challenge (or a
person's identity key, field/SPEC-id.md). That would replace the ssh key and
git-serve, and make `from` a real identity. Not built in 0096.

## 5. Checks on each pushed commit

Ticket 0154 (beck, design agreed with tova and ada in the ticket's branch).
Step 3 of 0095. A worker on the desktop (`lib/checks-worker` in
experiment) reads the `git.push` events, checks out each new commit in a
scratch worktree, and runs the checks the changed files call for. It
reports in scope `check/<repo>`, signed by its own identity `checks`
through node-chat (rules: `check/ id`).

| kind | body |
|---|---|
| `check.start` | `from checks`, `repo`, `commit <40 hex>`, `ref`, `checks <names, space-separated>` |
| `check.result` | `from checks`, `repo`, `commit`, `ref`, `status pass\|fail\|error`, a blank line, then one line per check: `<name> pass\|fail\|timeout <seconds>s` |

- A `check.result` has its `check.start` as its one parent.
- It links the job's log as a blob, `link blob <sha256> <size> text/plain`
  (SPEC-node 7.1), kept to the last 256 KB, so the log reaches server3 and
  the page can show it behind the login.
- `status` is `pass` when every check passed, `fail` when one failed or
  timed out, and `error` when the job itself could not run (the checkout
  failed, or the job hit its overall limit). An error says why in the text.
- A commit with no check the changed files call for still gets a
  `check.result`, with `status pass` and no check lines beyond the syntax
  pass.

**Reading it** (ada's /personal/prs, 0153): key on repo and commit, never
on ref, because a ref moves. The newest `check.result` for a commit is its
status. A `check.start` with no result means the checks are running. No
events at all means the commit has not been checked.

**Who writes it.** Like chat, anything on the desktop can post as `checks`:
the trust is the machine's (field/chat.wisp, top). A forged result can only
mislead. Merging still needs colin's signed approval of that exact head
(0153).
