# Actions: specification

Status: ticket 0155 (git platform), 2026-11-17. A draft by beck of the parts
built in step 1, the Actions core; ada (lead) owns this spec. Architecture:
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
| `network` | `"offline"` | `offline` or `internet`; enforced with the job user (§5 of the document, option (b)) |
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
| `action.result` | its start (or its job if it never started) | `from`, `job`, `repo`, `commit`, `ref`, `workflow`, `status pass\|fail\|error`, a blank line, then one line per step: `<name> pass\|fail\|timeout\|skip <seconds>s`, or `error: <why>` |

- **Dispatch.** The dispatcher posts one `action.job` per (repo, workflow,
  commit), never twice. A commit pushed under a second ref gets no second
  job.
- **Run.** A runner takes only jobs whose `runs-on` is its host, and whose
  `from` is the dispatcher's identity. It runs each job once, and records
  that before running it.
- **Logs.** A result links the job's log as a blob: `link blob <sha256>
  <size> text/plain`, the last 256 KB (SPEC-node 7.1).
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

## 4. Who writes it

`actions` (the dispatcher and the desktop runner, in one process for now)
signs every event through node-chat. As with chat, anything on the desktop
can post as `actions`: the trust is the machine's. Under option (a) jobs run
pushed code as colin. Option (b)'s field-jobs user is the hardening pass.
