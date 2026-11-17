# Deploys as actions: specification

Status: draft, ticket 0155 (ada and lux; design: doc `git-platform`,
decided, option (a), with every cheap item from doc `git-platform-security`).
A merge deploys the units it touched to a host, each as a bundle that a
listed key approved. The server3 runner installs it.

MUST, SHOULD and MAY are as in RFC 2119. Bodies are header lines, a blank
line, then text (SPEC-chat 4.1), with `from NAME` first. Times are ms since
1970.

**What this does and does not stop (option a).** Agents are root on server3
and jobs run as colin, whose ssh key is root there (doc
`git-platform-security`, F1-F3). So these checks stop honest mistakes and
leave a signed record of who approved what. They do not stop a hostile
agent, which can skip the runner. The hardening pass (0130, the field-jobs
user, private isolated through the supervisor of 0156) makes them binding.

## 1. Deploy units in the repo

`deploy/<unit>.toml` in the repo says what a unit would like installed. It
is a **request**: section 2 limits it, and the runner never trusts it alone.

```toml
unit = "transit"
host = "server3"
files = [                       # repo path -> installed path
  ["site/public/transit.js", "/var/lib/theater-repl/fs/public/transit.js"],
  ["site/public/transit-map.js", "/var/lib/theater-repl/fs/public/transit-map.js"],
]
services = []                   # restarted after installing
checks = ["site/check-chat --quick"]   # run on the desktop before the request
envs = ["prod"]                 # and "staging" once it exists (section 9)
```

- `unit` is a name as in section 2. `host` is `desktop` or `server3`.
- Together the units' `files` replace today's MANIFEST in
  `site/server3/deploy`. A file belongs to at most one unit, and the
  deploy workflow refuses a repo where two units claim one installed path.
- `checks` are commands run in a checkout of the commit on the desktop
  runner, as the deploy workflow's steps. Any failure stops the request.

## 2. The unit list (root's)

The runner trusts one file, **the unit list**, and never the repo's
`deploy/*.toml`. On server3 it is `/etc/field-deploy/units.toml`, owned by
root, mode 644, and installed or changed only by a colin-run step (`lib/run
propose desktop 'ssh server3 ...'`). A commit can never widen a unit's
approvers, paths or services.

```toml
[unit.transit]
approvers = ["<64 hex>", "<64 hex>"]   # the keys that may approve it
services  = ["private"]                # what a deploy may restart

[[unit.transit.path]]
prefix = "/var/lib/theater-repl/fs/public/"
owner  = "theater"
mode   = "644"

[[unit.transit.path]]
prefix = "/var/lib/theater-repl/fs/transit/"
owner  = "theater"
mode   = "644"
```

- A unit name is 1-32 of `a-z 0-9 -`.
- `approvers` are Ed25519 public keys, 64 lowercase hex. For a unit whose
  approver is colin's phone (private, field rules, anything under `/etc` or
  `bin/`), the list holds only the phone keys (SPEC-run 3).
- Each `prefix` is an absolute directory and ends in `/`. A prefix under
  `/etc/`, `/var/lib/theater-repl/bin/`, `/var/lib/theater-repl/keys/` or
  `/var/lib/theater-repl/secrets/` is allowed only in a unit whose approvers
  are all phone keys. The runner refuses a unit list that breaks this, so a
  mistake in the list fails closed.
- `mode` is three octal digits. Setuid, setgid and sticky bits are never
  set.
- The request's `deploy/<unit>.toml` MAY name fewer files and services than
  the list allows, never more.

## 3. Requests and bundles

**After a merge.** A merge to the repo's master runs the deploy workflow
(SPEC-actions) **as it is on master**, never from a branch or a PR
(doc `git-platform-security` R4), on the desktop runner. For each unit and
env:

1. It builds the unit's bundle at the merge commit (layout below) and
   compares each file's sha256 with what the unit's newest `deploy.done`
   for that env installed. A unit with no change stops here.
2. It runs the unit's `checks`. A failure posts nothing for that unit and
   says so in the merged PR's branch.
3. It puts the bundle as a blob (SPEC-node 7.1) and posts
   `deploy.request`.

| kind | scope | author | headers (then text) |
|---|---|---|---|
| `deploy.request` | `deploy/<unit>` | the dispatcher's runner key | `from`, `unit`, `env`, `host`, `commit`, `bundle <sha256>`, `version N`, `expires`, and `rollback V` for a rollback (section 9); text: each installed path that changes, a line each |
| `deploy.done` | `deploy/<unit>` | the server3 runner key | `from`, `request`, `unit`, `env`, `commit`, `bundle`, `version`; text: `<sha256> <path>` per installed file, then `service <name> up` per restarted service |
| `deploy.refused` | `deploy/<unit>` | the server3 runner key | `from`, `request`; text: the reason |

- A request has no parents, and a link `blob <sha256> <size>
  application/x-tar`. `expires` is its time plus 24 hours, unless the
  workflow says otherwise.
- `version` is one more than the highest `version` of the unit's
  `deploy.done` events for that env (1 for the first). It names a deploy
  for people and for rollback. The bundle sha256 is what binds.
- `deploy.done` and `deploy.refused` have the request as their one parent.
  A service that fails its 10 s check posts `deploy.refused` naming it, and
  the files stay installed, so an approver can roll back at once.

**Bundle layout** (fixed here because the install check depends on it): a
POSIX tar. Each member is a regular file named by its **installed path
without the leading `/`**, e.g. `var/lib/theater-repl/fs/public/transit.js`.
So the tar itself says where every file goes, and the runner checks that
against the unit list, with no repo mapping to look up. The bundle's id is
the sha256 of the tar's bytes.

The tar MUST be reproducible, so the same commit always gives the same
sha256 and anyone can rebuild it to check: members sorted by name, mtime 0,
uid and gid 0, mode 0644, no other entries. The installer ignores those
fields anyway (section 6).

## 4. Approving: `deploy.approve`

| kind | scope | author | body |
|---|---|---|---|
| `deploy.approve` | `deploy/approve/<unit>` | a key in the unit's `approvers` | headers below |
| `deploy.decline` | `deploy/approve/<unit>` | the same | `from`, `request`; blank line; the reason |

```
from tova
request 5c0e…(64 hex: the deploy.request's id)
unit transit
env prod
commit 1a2b…(40 hex)
bundle 9f86…(64 hex: sha256 of the bundle tar)
expires 1794081600000
```

- Its one parent is the request, so a node holds the request first.
- `unit`, `env`, `commit`, `bundle` and `expires` are copied from the
  request. As in SPEC-run 1.2, **the approval is the event's own
  signature**: the id covers them, and the key signs the id.
- A rollback is a request for an older bundle, so it is approved the same
  way, naming that bundle's sha256.
- `from` names who approved, for people. The runner trusts only the key.

## 5. What the runner checks before installing

The server3 runner follows `deploy/approve/<unit>`. For each
`deploy.approve` it installs only if all of these hold, and otherwise posts
`deploy.refused` with the reason, once per approval:

1. `/etc/field-deploy/STOP` does not exist (section 7).
2. The unit is in the unit list, and the list passes section 2's checks.
3. The approval's author is in **that unit's** `approvers` in the unit list,
   and its signature checks (SPEC-node 2.4). An approver of one unit cannot
   approve another.
4. The runner holds the request. It is the approval's `request` and its one
   parent, and it is in `deploy/<unit>`.
5. The approval's `unit`, `env`, `commit`, `bundle` and `expires` equal the
   request's, and now is before `expires`.
6. No `deploy.decline` for the request is held.
7. The request has not been installed before. The runner records the
   request id in its ledger **before** it installs, so a crash never
   installs one twice. A `deploy.done` for the request in the field also
   counts.
8. The bundle it fetched has the approved sha256.
9. Every member passes section 6.

Steps 1-8 cost nothing to keep in option (a), so they are kept.

## 6. Installing a bundle

For each tar member, before anything is written:

- It MUST be a regular file: no directories, symlinks, hard links,
  devices or FIFOs.
- Its name, with a `/` in front, MUST be a normalized absolute path: no
  `.` or `..` component, no empty component, no NUL byte, at most 4096
  bytes. It MUST start with one of the unit's prefixes.
- No component of the path on disk below the prefix may be a symlink when
  the runner writes it (it opens each directory without following links).
- A file named `*.wisp` that a service starts (a start file) MUST be at
  most 4096 bytes, as deploy checks today.
- Owner and mode come from the matching prefix in the unit list. The tar's
  owner, mode and times are ignored.

If any member fails, nothing is installed. Otherwise each file is written
to a temporary file in its directory, synced, given its owner and mode, and
renamed into place. The file it replaces is kept as `<file>.prev`, as
deploy does today. Then the runner restarts the request's services (each one
in the unit's `services`) and checks that each is still running 10 s later.

## 7. The stop switch

`/etc/field-deploy/STOP`, a root-owned file: while it exists, the runner
installs nothing and refuses each approval with `stopped`. Colin creates or
removes it with one colin-run step. It is a brake that needs no code
change. An agent that is root can remove it too, which is option (a)'s
honest limit.

## 8. Rules

```
deploy/ <server3 runner key>
deploy/ <the dispatcher's key>
deploy/approve/<unit> <each key in that unit's approvers>
```

- `deploy/approve/<unit>` lines are per unit and longer than `deploy/`, so
  they decide alone for approvals (SPEC-node 5).
- Until a unit has approvers, its line is `deploy/approve/<unit> none`, and
  the scope is closed.
- Node rules stop honest mistakes. The runner's own unit list (section 2)
  is the real check, as with SPEC-run 2.

## 9. Rollback, environments, services and pages

**Rollback.** A rollback is a `deploy.request` with `rollback V`, naming
the bundle that the unit's `deploy.done` version V installed (the same
sha256, fetched again as a blob). It is approved and installed exactly
like a deploy (section 4): one signed tap, never automatic. Its own
`version` is the next number, so the history reads forward.

**Environments.** `prod` is the host's daemon. `staging`, once it exists, is
a second daemon on the same host, with its own fs root and ports and its
own prefixes in the unit list (`[unit.transit.staging]`). It tests the
deploy, not security: it runs as the same user.

**Services.** Until ilse's root supervisor (0156) exists, the runner restarts
a service through the daemon, as deploy does today (`theater-repl
services`, then the 10 s check). Once it exists, the runner asks the
supervisor, and the unit list's `services` are supervisor children.

**Pages.** `/personal/deploys` lists the units, each with its versions
(commit, bundle, who approved, when, services up), the open requests with
an Approve button for the viewer's key when it is one of the unit's
approvers, and a Roll back button on each earlier version. A PR's page
shows the deploys its merge started.
