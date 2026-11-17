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

(ada: `deploy/<unit>.toml`: files as `<repo path> <installed path>`,
services, checks, environments. It is a request; section 2 limits it.)

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

(ada: `deploy.request` in `deploy/<unit>`, after a merge: unit, env, commit,
bundle sha256, version, expires; the bundle as a blob; environments.)

**Bundle layout** (fixed here because the install check depends on it): a
POSIX tar. Each member is a regular file named by its **installed path
without the leading `/`**, e.g. `var/lib/theater-repl/fs/public/transit.js`.
So the tar itself says where every file goes, and the runner checks that
against the unit list, with no repo mapping to look up. The bundle's id is
the sha256 of the tar's bytes.

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

## 9. Rollback, environments and pages

(ada.)
