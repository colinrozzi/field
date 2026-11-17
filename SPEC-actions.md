# Actions: specification

Status: ticket 0155 (git platform), 2026-11-17. A draft by beck of the parts
built in step 1, the Actions core, with lux's review of it (section 5);
ada (lead) owns this spec. Architecture:
the document `git-platform` (§2, §3, §8).

Workflows run on pushes, as jobs on a runner per host. Every step is a field
event, in scope `actions/<repo>`, so chat, the pages and agents all see the
same record. Experiment's runner is `lib/actions-runner`.

MUST, SHOULD and MAY are as in RFC 2119. Bodies are header lines, a blank
line, then text (SPEC-chat 4.1), with `from NAME` first.

## 1. Workflows

A workflow is `.actions/<name>.toml` in the repo, read **at the pushed
commit**, so a branch can change its own workflows. `<name>` is a name (SPEC-chat
5.1). Keys (unknown keys make the file invalid):

| key | default | meaning |
|---|---|---|
| `on` | `["push"]` | triggers: `push` (a branch moved), `merge` (master moved), `tag` (a new tag); `pr` and `timer` are reserved |
| `branches` | `["*"]` | fnmatch globs on the branch name, for `push` and `merge` |
| `runs-on` | `"desktop"` | `desktop` or `server3`; Rust only on the desktop |
| `memory` | `"4G"` | each step's MemoryMax |
| `timeout` | `900` | seconds per step |
| `job-timeout` | `2700` | seconds for the job |
| `network` | `"offline"` | `offline` or `internet`. **Not enforced under option (a)**: every job has the network until the job user of option (b) (PrivateNetwork). Don't rely on it |
| `secrets` | `[]` | secret names, granted in the store; for master workflows only. **Not wired yet**: a job whose workflow lists any ends with `status error` |
| `syntax` | `false` | first run the syntax pass on the changed files: bash -n, python compile, node --check, TOML, and Wisp parenthesis balance |
| `assets` | `[]` | gitignored files a step needs (paths inside the worktree, no `..`): the runner keeps one copy and links it in |
| `[[step]]` | | `name`, `run` (bash, in the worktree's root), and optional `paths` |

A step with `paths` runs only when a changed file matches one of its globs
(fnmatch: `*` also matches `/`), or when its own script (`run`'s first
word) changed. A step without `paths` always runs.

A file that doesn't parse, or breaks a rule above, starts no job. The runner
logs why.

## 2. Events

All in scope `actions/<repo>`. Rules: `actions/ id`.

| kind | parent | body |
|---|---|---|
| `action.job` | none | `from`, `repo`, `commit <40 hex>`, `ref`, `old <40 hex>`, `workflow`, `trigger`, `runs-on` |
| `action.start` | its job | `from`, `job <job id>`, `repo`, `commit`, `ref`, `workflow`, `steps <names, space-separated, or ->` |
| `action.result` | its start (or its job if it never started) | `from`, `job`, `repo`, `commit`, `ref`, `workflow`, `status pass\|fail\|error`, a blank line, then one line per step: `<name> pass\|fail\|timeout\|skip <seconds>s`, or `error: <why>`; then the logs: `log <step> <sha256> <bytes>` per step (`log - ...` for the whole job's tail; `log <step> - 0` for one over the job's cap) |
| `action.rerun` | none | `from`, `repo`, `commit <40 hex>`, optional `workflow`: a request to run that commit's push workflows (or the one named) again |

- **Dispatch.** The dispatcher posts one `action.job` per (repo, workflow,
  commit), never twice. A commit pushed under a second ref gets no second
  job.
- **Run.** A runner takes only jobs whose `runs-on` is its host, whose
  `from` is the dispatcher's identity, and whose **author key** is a current
  key of that identity (SPEC-id). The node already admits an event under the
  `id` rule only from a current key of the identity its `from` names (SPEC-id
  5); the runner checks again, so a job never rests on the rules alone. It runs each
  job once, and records that before running it.
- **Logs.** Each step's own output is a blob of its own: its last 8 KB when
  it passed, 64 KB when it failed or timed out, and at most 512 KB for all of
  a job's steps. The whole job's tail (64 KB) is one more, for errors outside
  a step. The result links each (`link blob <sha256> <size> text/plain`,
  SPEC-node 7.1) and names it on a `log` line, so a log is bound to its job
  and step by the runner's signed event, and a step cannot pass off its
  output as another's by printing markers. Before upload the runner removes
  ANSI and other control sequences, keeps a line's last carriage-return
  rewrite, and makes it valid UTF-8. A page MUST still treat a log as
  untrusted text: escape it, render no escape sequence, and make no link of
  a URL in it. **Logs are visible to everyone with the login**, and to
  every store that holds the scope; once jobs get secrets, the runner masks
  each secret's value before upload (5.3).
- **Rerun.** `action.rerun` is a request, not a job: the runner counts it
  only from its rerun identities (colin and tova), by a current key of the
  one its `from` names, and turns it into the same jobs as `--rerun`, each
  with the request as its parent and trigger `rerun`: **push workflows only**
  (never a merge, tag or deploy workflow, even one named), at a commit its
  mirror holds, at most one per (commit, workflow) a minute.
- **Status.** `pass` when the syntax pass and every step passed. `fail` when
  one failed or timed out. `error` when the job could not run: the checkout
  failed, the workflow was gone or invalid, it lists secrets, or it hit
  `job-timeout`.
- **The `checks` workflow** also posts `check.start` and `check.result` in
  `check/<repo>` (SPEC-git 5), with the same status and lines, for the PR
  page and pr-merge.

## 3. Reading it

- Key on repo and commit.
- A job with no start is queued. A start with no result is running.
- The newest result for a (workflow, commit) is that workflow's status for
  the commit.
- Count a result (and a `check.result`) only when its `from` is `actions` or
  `checks`. Every identity may write in these scopes as itself, so a result
  from any other identity (a `check.result` from `tova` saying pass) is not a
  check. The node has already tied `from` to the author key (SPEC-id 5).
  lib/pr and deploy-request check the author key against those identities;
  the PR and commit pages check `from`.

## 4. Who writes it, and the environment of a step

`actions` (the dispatcher and the desktop runner, in one process for now)
signs every event through node-chat. As with chat, anything on the desktop
can post as `actions`: the trust is the machine's. Under option (a) jobs run
pushed code as colin. Option (b)'s field-jobs user is the hardening pass.

A step SHOULD run with a minimal environment (PATH, HOME, LANG, TMPDIR and
the job's own variables), never the runner's whole environment, so that
whatever is in it (an `SSH_AUTH_SOCK`, a token) doesn't reach a job by
accident.

## 5. Before any job gets secrets (lux's review)

Secrets are refused today (a workflow that lists any ends in `error`).
Before that changes, all of these MUST hold (doc `git-platform-security`
R4, R6):

1. **The job event is not trusted for anything that grants rights.** Every
   desktop id key is signable by any agent (SPEC-id 5), so a job whose
   `from` says `actions` may still be forged. The runner checks that the
   event's **author key** is the actions key, and then works out for itself,
   from its mirror of server3's repo, that the commit is on
   `refs/heads/master` and that the trigger was `merge`.
2. **The secrets list comes from the workflow as it is on master** at that
   commit, never from a branch or a PR. Which workflow may read which
   secret is a grant colin makes in the secrets store
   (`wf-<repo>-<name>`, e.g. `wf-experiment-deploy`: the secrets helper
   takes only a-z, 0-9 and -, as repo and workflow names already are), not
   the workflow file's own claim.
3. **Logs.** A job that got secrets keeps its full log on the host, and only
   the masked log goes in the blob, since a blob reaches every store that
   holds the scope.
4. Each secret fetch posts `secret.read` with reader
   `wf-<repo>-<name>` and the job id.

Later, for option (b): the runner runs from a root-owned copy, as
`lib/runner` does, so that an edit to it in the shared checkout doesn't take
effect at its next restart unreviewed.

## 6. What's next here

- `pr` (a PR opened or pushed) and `timer` triggers.
- `runs-on = "server3"`: the server3 runner, which also installs deploys
  (SPEC-deploy). Its jobs stay queued until it exists.
- The deploy workflow (SPEC-deploy §3) is a `merge` workflow on master.
- `/personal/actions`: jobs, their steps and logs, by repo and commit.
