# Pull requests on the field: specification

Status: ticket 0153, 2026-11-17 (ada). Step 2 of the self-hosted development
cycle (0095): review. The design was agreed with tova in the chat branch
`self-hosted-git-step-2-review-a-pr-is-a`. Step 1 put the repo on server3
and records each push (field/SPEC-git.md). Step 3 (0154, beck) posts checks.

A **pull request** asks to merge a branch of a repo on server3 into its base
branch. It is a chat branch, the way a ticket is (field/CHAT.md): its state
says what it is, its messages are the discussion, and an approval is a
signed event. Approvers are listed **per repo** in the rules, and nothing
else can approve. Readers: `lib/chat` (the `pr` verbs) and
`site/public/chat.js` (`/personal/prs`).

MUST, SHOULD and MAY are as in RFC 2119. Names are SPEC-chat 5.1's. A
`SHA` is a commit id, 40 lowercase hex.

## 1. A PR is a branch with state

`lib/chat ME pr-new REPO BRANCH` makes a chat branch, named
`pr-<N>-<slug of the title>`. Its state keys (`chat.set`, newest wins):

| key | value |
|---|---|
| `pr` | `N`, the PR's number: one past the highest any branch has |
| `title` | one line |
| `repo` | the repo's name on server3 (`experiment`) |
| `ref` | the branch: `refs/heads/BRANCH` |
| `base` | the branch it merges into: the repo's default branch on server3, its `HEAD` (`refs/heads/master` for experiment, `refs/heads/main` for wisp) |
| `status` | `open`, `merged` or `closed` |
| `ticket` | optional: the ticket it does. Merging sets that ticket to `done` |

A branch whose state has a non-empty `pr` is a PR. A PR branch has no
`n`, so it is never a ticket. Its first message is written by `pr-new`: the
summary, then `git diff --stat` from the merge base to the head, then the
diff link `/personal/prs/N/diff`. Its group (SPEC-group) holds the author,
plus whoever pr-new is told to add.

**The head is not stored.** A PR's head is the `new` of the newest
`git.push` in `git/REPO` whose `ref` is the PR's `ref` (SPEC-git 2), and its
author is that event's `from`. So pushing more commits to the branch moves
the PR with no other step. A reader shows each such push in the PR (old to
new). A push that deletes the ref (`new` all zeros) leaves the PR with no
head: it cannot be approved or merged until the branch is pushed again.

`base` holds a name, not a commit. The **merge base** is computed by git
when needed, from the repo on server3.

## 2. Approvals

| kind | scope | author | body |
|---|---|---|---|
| `pr.approve` | `pr/approve/REPO` | one of REPO's approver keys | headers `from`, `pr N`, `repo`, `ref`, `head SHA`; blank line; an optional note |
| `pr.decline` | `pr/approve/REPO` | one of REPO's approver keys | headers `from`, `pr N`, `repo`, `ref`, `head SHA`; blank line; what to change |

- No parents. An approval names everything it approves in its own headers,
  and those are signed with it (SPEC-node 2.3, 2.4).
- `head` is the exact commit approved. The approval holds only while it is
  the PR's head: after another push the PR shows "approved at <head>,
  now at <newer>", and needs a new approval.
- `pr.decline` asks for changes. It closes nothing. The newer of the newest
  approval and the newest decline for the current head is the PR's review
  state. Compare by event `time`, then id.
- The note or reason MAY be empty, and is at most what the node takes.

**Approver keys are per repo.** The rules (SPEC-node 4) carry one line per
key:

```
pr/approve/experiment <tova's id key>
pr/approve/experiment <colin's phone approver key>
pr/approve/field <colin's phone approver key>
```

- For `experiment`: tova's identity key and colin's phone. An experiment
  merge has needed no review from colin until now, so an agent can approve.
- For `field` and `theater` (later): colin's phone key only (SPEC-run 3).
  That key never leaves his phone, so no agent can make that approval.
- A repo with no line is closed: nobody can approve a PR on it. Until
  colin registers his phone key, its lines are left out.
- Rules match by plain string prefix (SPEC-node 5), so the lines for
  `experiment` also admit `pr/approve/experiment-x`. A repo whose name
  starts with another repo's name MUST get its own lines, which, being
  longer, then decide alone.
- tova approves through node-chat, which signs with `id.tova` like any of
  tova's events (`lib/chat tova pr-approve N`). colin approves on the PR page,
  signed in his phone's browser as `run.approve` is (SPEC-run 3, 5), and
  posted through `/personal/live/admit`.
- The honest limit: a desktop identity key, like tova's, can be used by
  any session in the desktop daemon (SPEC-id 5). So an experiment
  approval keeps honest mistakes out, and makes it plain who approved. A
  field or theater approval is the one no agent can forge.

## 3. Merging

`lib/chat tova pr-merge N` merges a PR only if all of these hold:

1. `status` is `open`.
2. The PR has a head, and server3's branch is at that head
   (`git ls-remote`).
3. The newest review event for that head is a `pr.approve`, its author is
   on the repo's approver lines in this node's rules, and it is in the
   node (the node checked its signature on admission).
4. When checks are expected: the newest `check.result` in `check/REPO`
   whose `commit` is the head has `status pass`. Checks are expected once
   the repo has any check events, or when the head carries the checks
   workflow (`.actions/checks.toml`). Then "no result yet" means the runner
   hasn't reached that head, never "nothing to check". Only a check event
   signed by a current key of the `actions` or `checks` identity counts
   (SPEC-id), since any agent can post one under any name.

Then, in a scratch worktree of the desktop's clone: `git merge --no-ff` of
**the head commit the approval names** (never the branch's tip at merge
time, so a push after the approval cannot slip in) into `base`, with the message
`Merge PR N: TITLE` and the trailer `Approved-by: NAME <approval id>`. It
pushes `base` to server3, sets `status merged` and the ticket's `status
done`, and posts the merge commit in the PR. A merge conflict stops it,
and it says so in the PR. `pr-close N` sets `status closed` with no merge.
A closed PR can be opened again (`pr-set N status open`).

**The merger** (`lib/chat runner.desktop pr-merge-asked`, each minute)
merges for the page, so no merge runs in the site:
- **Merge button:** a PR whose state `merge` is its head is merged. A
  refusal is posted in the PR and clears `merge`.
- **Auto-merge:** a PR whose state `auto-merge` is `yes` is merged once its
  head is approved and its checks pass (or none are expected). It waits
  without counting while checks are expected and have no result. A refusal
  is posted once per head, and after 3 refusals at one head `auto-merge`
  clears itself and says so. Setting either key grants nothing:
  `pr-merge` checks all of the above again.
- **Re-review:** once per new head, when a push moves past the newest
  review by an approver, it posts "Pushed OLD -> NEW since @REVIEWER's
  approval (or request for changes). Please look again."

**Not yet enforced by server3.** The checks above are made by whoever
merges. A pre-receive hook on server3 could refuse an update of `base`
that isn't a merge of an approved head. That changes everyone's flow,
because base is pushed directly today, so it is left off until colin
decides.

## 4. The page

- `/personal/prs` lists the open PRs: number, title, repo, author, head
  (short), checks (pass, fail, running, or none) and review state
  (approved, changes asked, stale, waiting).
- A PR's page is its branch, with a panel on top: the diffstat, a link to
  the diff, the checks with their log link, and Approve and Request
  changes buttons, shown only to an approver of that repo.
- `/personal/prs/N/diff` is the diff from the merge base to the head, made
  by git on server3 from the bare repo (`git diff BASE...HEAD`), behind the
  login. Diffs are never put in the field, so there is no size limit and
  nothing large is copied.
- **Line comments.** A comment on a line of the diff is a `chat.msg` in the
  PR's branch with two more headers: `line PATH:N` (line N of PATH in the
  new file) and `at SHA` (the head it was written on). So replies,
  threads, mentions and mail work as for any message. The diff page shows
  a comment under its line when `at` is the current head. Comments at an
  older head, or on a file not in the diff, are listed apart, never moved.
  PATH and N are agent-written, so they are drawn only as text, and N must
  be a decimal number. From a shell: `lib/chat ME pr-comment N PATH LINE
  TEXT`; on the page, the + beside a line.

## 5. Conformance

A PR reader MUST derive the head, the review state and the checks as
sections 1 to 3 say. The cases are in `lib/chat`'s PR tests
(`lib/pr-test`), which build PRs from made-up events, since no field
model is involved beyond chat's.
