# Deploys as actions: specification

Status: draft, ticket 0155, 2026-11-17 (ada, with lux). From the decided
document `git-platform` (§5 choice (a), with every cheap item: R3, R4-R6,
R8 of lux's review, doc `git-platform-security`). The trust module is lux's
`lib/deploy_trust.py`, and the runner beck's. Actions themselves are in
SPEC-actions.md (beck).

A **deploy unit** is one part of a repo that is installed on a host as a
whole: its files, the services to restart, and who approves it. A merge to
master deploys each unit whose files changed. Every deploy installs one
**bundle**, a tar of exactly the files to install, approved by a signed
event that names it. The host's runner installs it, so no agent copies
files by hand. A rollback installs an older bundle the same way.

MUST, SHOULD and MAY are as in RFC 2119. Bodies are header lines, a blank
line, then text (SPEC-chat 4.1), with `from NAME` first. Times are ms
since 1970.

## 1. Units

**The request: `deploy/<unit>.toml` in the repo.** It says what the unit
would like installed. It is never trusted on its own (section 2).

```toml
unit = "transit"
host = "server3"
files = [                      # repo path -> installed path
  ["site/public/transit.js", "/var/lib/theater-repl/fs/public/transit.js"],
  ["site/public/transit-map.js", "/var/lib/theater-repl/fs/public/transit-map.js"],
]
services = []                  # services to restart after installing
checks = ["site/check-chat --quick"]   # run on the desktop before asking for approval
envs = ["prod"]                # and "staging" once it exists
```

`<unit>` is a name (SPEC-chat 5.1). Together, the units' files replace
today's MANIFEST in `site/server3/deploy`. A file belongs to at most one
unit: the deploy workflow refuses a repo where two units claim one
installed path. `checks` run in a checkout of the commit on the desktop
runner, as the deploy workflow's steps.

**The root copy: `/etc/field-deploy/units.toml` on the host,** owned by
root, mode 644, and installed or changed only by a step colin runs (`lib/run
propose desktop 'ssh server3 ...'`). It is the one file the runner trusts:

```toml
[unit.transit]
approvers = ["<64 hex>", "<64 hex>"]   # keys that may approve this unit
services  = []                         # services a deploy may restart

[[unit.transit.path]]
prefix = "/var/lib/theater-repl/fs/public/"
owner  = "theater"
mode   = "644"
```

- `approvers` are Ed25519 public keys, 64 lowercase hex. For a phone-tier
  unit (private, field rules, anything under `/etc` or a `bin/`) they are
  only colin's phone keys (SPEC-run 3).
- Each `prefix` is an absolute directory ending in `/`. A prefix under
  `/etc/`, `/var/lib/theater-repl/bin/`, `/var/lib/theater-repl/keys/` or
  `/var/lib/theater-repl/secrets/` is allowed only in a unit whose approvers
  are all phone keys.
- `mode` is three octal digits; setuid, setgid and sticky are never set.
- **It fails closed.** A root copy that breaks any rule above is refused as
  a whole, and nothing is installed until colin fixes it.

`/etc/field-deploy/STOP` is the stop switch (section 5a).

## 2. What the root copy decides

The repo's toml is a request. The runner checks every bundle against the
root copy and refuses anything wider. So a commit can never widen a unit's
approvers, paths, owners, modes or services (R1). Changing those is a new
root copy, which colin installs.

## 3. Bundles

A bundle is a tar of the unit's files **at one commit**:
- each member is named by its installed path without the leading `/`
  (`var/lib/theater-repl/fs/public/transit.js`), so the tar says where
  every file goes and the installer checks that against the root copy;
- members are regular files only, sorted by name, with mtime 0 and owner
  0:0 (owner and mode come from the root copy, never the tar), so the same
  commit always gives the same bytes and the same sha256;
- it is put as a blob (SPEC-node 7.1), and the events name its sha256.

## 4. Events

| kind | scope | author | headers (then text) |
|---|---|---|---|
| `deploy.request` | `deploy/<unit>` | the deploy workflow's runner (`runner.desktop`) | `from`, `unit`, `env`, `host`, `commit`, `bundle <sha256>`, `version N`, `expires`, `rollback <old version>` (only for a rollback); text: the installed paths that change, a line each |
| `deploy.approve` | `deploy/approve/<unit>` | one of the unit's approver keys | `from`, `request <id>`, `unit`, `env`, `commit`, `bundle`, `expires` |
| `deploy.decline` | `deploy/approve/<unit>` | an approver key | `from`, `request <id>`; text: why |
| `deploy.done` | `deploy/<unit>` | the host's runner (`runner.<host>`) | `from`, `request`, `unit`, `env`, `commit`, `bundle`, `version`; text: `<sha256> <path>` per installed file, then `service <name> up` per restarted service |
| `deploy.refused` | `deploy/<unit>` | the host's runner | `from`, `request`; text: the reason |

- `deploy.request` has no parents and a `link blob <sha256> <size>
  application/x-tar`. `expires` is its time plus 24 hours unless the
  workflow says otherwise. `version` is one more than the highest version
  of the unit's `deploy.done` events for that env (1 for the first): it
  names a deploy for people and for rollback, and the bundle sha256 is what
  binds.
- `deploy.done` and `deploy.refused` have the request as their one parent.
- `deploy.approve` and `deploy.decline` have the request as their one
  parent. The approval binds unit, env, commit, bundle and expiry, which
  are copied from the request and signed with it (R2). It is used once.
- Rules on both nodes: `deploy/ <runner keys>` for requests and results,
  and `deploy/approve/<unit> <approver keys>` per unit, the same keys as
  the root copy's. The per-unit lines are longer, so they decide alone for
  approvals (SPEC-node 5), and an approver of one unit cannot approve
  another. Until a unit has approvers, its line is
  `deploy/approve/<unit> none`, and the scope is closed. The rules stop
  honest mistakes; the root copy is the real check (as SPEC-run 2).
- `from` in an approval names who approved, for people. The runner trusts
  only the signing key.

## 5. The flow

1. **A merge to master** runs the deploy workflow from master (never from
   a branch or a PR: R4), on the desktop runner. For each unit and env, it
   compares the unit's files at the merge with what the newest
   `deploy.done` installed (by sha256), and stops for a unit with no
   change.
2. It runs the unit's `checks`, builds the bundle, puts the blob, and
   posts `deploy.request`. A failing check posts nothing and says so in
   the merge's PR.
3. **An approver approves.**
   - For transit, chat/docs and mail: the unit's lead or tova.
   - For private, field rules, and anything under `/etc` or a `bin/`:
     colin's phone key.
   - Until (b), a unit that ships `.wisp` to the shared daemon reaches what
     private reaches. That is the honest note of choice (a).
4. **The host's runner** follows `deploy/approve/`. For each approval,
   `check_approval` (lux's module) passes only if all of these hold, and
   otherwise the runner posts `deploy.refused` with the first reason, once
   per approval:
   1. `/etc/field-deploy/STOP` does not exist (5a);
   2. the root copy exists, passes section 1's rules, and lists the unit;
   3. the approval's author is in **that unit's** `approvers` in the root
      copy, and its signature checks (SPEC-node 2.4);
   4. the runner holds the request; it is the approval's `request` and its
      one parent, and it is in `deploy/<unit>`;
   5. the approval's unit, env, commit, bundle and expires equal the
      request's, and now is before `expires`;
   6. no `deploy.decline` for the request is held;
   7. the request was never installed: the runner writes the request id to
      its ledger **before** installing, so a crash never installs it twice,
      and a `deploy.done` for it in the field also counts.

   Then `install_bundle` checks **every member before writing any**, so a
   bundle installs whole or not at all:
   - the blob's sha256 is the approved bundle's;
   - each member is a regular file (no directory, symlink, hard link,
     device or FIFO);
   - its name, with `/` in front, is a normalized absolute path (no `.`,
     `..` or empty component, no NUL, at most 4,096 bytes) under one of the
     unit's prefixes;
   - no directory between the prefix and the file is a symlink when it is
     written (each directory is opened without following links);
   - a `serve-*.wisp` start file is at most 4,096 bytes;
   - **live drift** (0115): a file on the host that differs from what the
     runner last installed there stops the whole install. It is checked
     here, against the runner's own record of installed sums, so it fails
     together with the other checks, before any write.

   Each file is then written to a temp file in its directory, synced, given
   the owner and mode of its prefix in the root copy (never the tar's), and
   renamed into place, with the old one kept as `.prev`. The record of
   installed sums is updated after the last rename.
5. It restarts the unit's services, only those both the request and the
   root copy name. Each must still be running, with no restart, 10 s
   later, as deploy checks today. Then it posts `deploy.done`, or
   `deploy.refused` with the first reason.
6. A failed service check posts `deploy.refused` naming the service, and
   leaves the files installed, so an approver can roll back at once.

## 5a. The stop switch

While `/etc/field-deploy/STOP` (root's) exists, the runner installs
nothing and refuses each approval with `stopped`. colin creates or removes
it with one colin-run step; it needs no code change. Under choice (a) an
agent that is root can remove it too.

## 6. Rollback

A rollback is a `deploy.request` with `rollback <version>`, naming the
bundle that `deploy.done` version installed. It is approved and installed
exactly like a deploy (R2): one signed tap, never automatic.

## 7. Environments

`prod` is the host's daemon. `staging`, once it exists, is a second daemon
on the same host with its own fs root and ports, and its own prefixes in
the root copy. Staging tests the deploy, not security: it runs as the same
user (R8).

## 8. Services and the supervisor

Until ilse's root supervisor (0156, doc `root-supervisor`) exists, the
runner installs in place and restarts a service through the daemon, as
deploy does today (`theater-repl services`, then the 10 s check).

Once it exists, a unit whose root copy says `layout = "versioned"` changes
in three ways:
- **Where.** Its bundle is installed under `units/<unit>/<env>/<n>/`, where
  `n` is the request's `version` (counted per unit and env), not over the
  live files. If staging becomes its own daemon with its own fs root, the
  path drops back to `units/<unit>/<n>/` there. Each member's name
  is then its path inside that directory (`public/transit.js`), and the
  root copy's prefixes are relative to it. Old and new versions sit side
  by side, and the child's fs grant points at its own version.
- **Restart.** The runner does not restart anything itself. After
  installing, it sends the supervisor `deploy <unit> <n>` and waits for the
  answer: started, healthy, and still up after the settle time, or
  `failed <step> <why>`.
- **Done.** It posts `deploy.done` from a success, and `deploy.refused`
  with the supervisor's step and reason from a failure. In that case the
  supervisor has already left version n-1 serving.

A rollback to version V is then `deploy <unit> V` of a bundle still on
disk. The request and approval stay as in section 6, so a rollback is still
one signed tap. In-place units (anything not run by a supervised child, such
as `/etc` files) keep the in-place install.

## 8a. Pages

`/personal/deploys` lists the units, each with its versions (commit,
bundle, who approved, when, services up), the open requests with an
Approve button when the viewer's key is one of the unit's approvers, and a
Roll back button on each earlier version. A PR's page shows the deploys its
merge started.

## 9. Conformance

lux's `lib/deploy_trust.py` test covers sections 2 to 5 (the approval
checks and the installer). The runner's end-to-end test installs the
transit unit on a throwaway daemon: deploy, refuse a widened path, refuse
a second use, roll back.
