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
unit.

**The root copy: `/etc/field-deploy/units.toml` on the host,** owned by
root and installed by a step colin runs (`lib/run propose`). For each unit
it lists `approvers` (64-hex keys), `services` it may restart, and `paths`,
a list of `{prefix, owner, mode}`. `/etc/field-deploy/STOP` existing stops
every install (R8).

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

- `deploy.request` has a `link blob <sha256> <size> application/x-tar`.
  `version` is one more than the unit's newest `deploy.done` for that env.
- `deploy.approve` and `deploy.decline` have the request as their one
  parent. The approval binds unit, env, commit, bundle and expiry, which
  are copied from the request and signed with it (R2). It is used once.
- Rules on both nodes: `deploy/ <runner keys>` for requests and results,
  and `deploy/approve/<unit> <approver keys>` per unit, the same keys as
  the root copy's.

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
4. **The host's runner** follows `deploy/approve/`. For each approval it
   runs `check_approval`, then `install_bundle` (lux's module):
   - the STOP file is absent;
   - the signer is one of the unit's approvers in the root copy;
   - the approval's one parent is the request, and unit, env, commit,
     bundle and expiry match it, and now is before `expires`;
   - the request has not been installed before (a ledger, written before
     installing);
   - the blob's sha256 is the approved bundle's;
   - every member is a regular file whose normalized name lies under one
     of the unit's prefixes, with no `..` and no link;
   - a `serve-*.wisp` start file is at most 4,096 bytes;
   - a file on the host that differs from what the runner last installed
     there (live drift, 0115) stops the install;
   - each file is written to a temp file and renamed into place, with the
     old one kept as `.prev`, and its owner and mode from the root copy.
5. It restarts the unit's services, only those both the request and the
   root copy name. Each must still be running, with no restart, 10 s
   later, as deploy checks today. Then it posts `deploy.done`, or
   `deploy.refused` with the first reason.
6. A failed service check posts `deploy.refused` naming the service, and
   leaves the files installed, so an approver can roll back at once.

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

Until ilse's root supervisor (0156) exists, the runner restarts a service
the way deploy does today, through the daemon (`theater-repl services`).
Once it exists, the runner asks the supervisor, and the root copy's
`services` become supervisor children.

## 9. Conformance

lux's `lib/deploy_trust.py` test covers sections 2 to 5 (the approval
checks and the installer). The runner's end-to-end test installs the
transit unit on a throwaway daemon: deploy, refuse a widened path, refuse
a second use, roll back.
