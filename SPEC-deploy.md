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
after = []                     # units a merge must deploy first (below)
auto = false                   # approve itself on a green merge (below)
```

`<unit>` is a name (SPEC-chat 5.1). Together, the units' files replace
today's MANIFEST in `site/server3/deploy`. A file belongs to at most one
unit: the deploy workflow refuses a repo where two units claim one
installed path. `checks` run in a checkout of the commit on the desktop
runner, as the deploy workflow's steps.

**Order between units.** Units deploy independently, so a merge that
changes two of them posts two requests that nothing orders. Prefer changes
that work in either order (a new file that old code ignores, code that
works without it). Where that isn't possible, `after` names the units that
must be installed first when the same merge changes them too (e.g. private
`after = ["pages"]`, since private.wisp loads pages' page.js). `after` only
orders requests and widens nothing, so the repo's file is trusted for it.
It is inactive until the units are.

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
- A path entry has either `prefix`, a directory ending in `/` (all files
  below it), or `file`, one exact file (`file =
  "/var/lib/theater-repl/fs/private.wisp"`). Shared directories (`fs/`,
  `public/`) hold files of several units, so those units list their files
  one by one. One file belongs to exactly one unit: the same file in two
  units, or a file under another unit's prefix, refuses the root copy.
- Each `prefix` is an absolute directory ending in `/`. A path under one
  of the root copy's `phone_only_prefixes` is allowed only in a unit whose
  approvers are all phone keys. When the setting is missing, those are
  `/etc/`, `/var/lib/theater-repl/bin/`, `/var/lib/theater-repl/keys/` and
  `/var/lib/theater-repl/secrets/`. While we iterate, tova's root copy sets
  `phone_only_prefixes = []` (section 5, step 3).
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
| `deploy.request` | `deploy/<unit>` | the deploy workflow's runner (`runner.desktop`) | `from`, `unit`, `env`, `host`, `commit`, `bundle <sha256>`, `version N`, `expires`, `services <names, space-separated, or ->`, `after <units, space-separated, or ->`, `rollback <old version>` (only for a rollback), `installed <version> <commit or ->`, `age newer\|rollback`; text: the installed paths that change, a line each |
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
- **`installed` and `age`** (lux, tova, 2026-11-17): what that env had
  installed when the request was made (the newest `deploy.done`'s version
  and commit; `0 -` for nothing), and how the request compares: `newer`
  (its commit has something the installed one lacks), or `rollback`. The
  workflow posts nothing else: a commit that is the installed one or an
  ancestor of it, or one git can't place (unknown counts as older), asks
  for nothing, and going back is a rollback (section 6). A reader that
  can't compare by git, the approval page on colin's phone, shows these
  two as text and warns unless `age` is `newer` or `rollback`; a reader
  that can (the deploys page, by the code browser's `range`; `deploy-request
  --approve`, by `git merge-base --is-ancestor`) also says when a request is
  older than what is installed, and asks for `--downgrade` before signing
  one. They are the runner's signed claims, so they guard against mistakes
  (a stale request after a stall), not a forger: the host's runner checks
  `installed` against its own record of what it installed (section 5).
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
   - **While we iterate** (colin, 2026-11-17): tova approves every unit,
     and the root copy sets `phone_only_prefixes = []`. Ship fast and
     often.
   - The phone tier stays in the code as a later option, one line in the
     root copy each: a unit's approvers set back to colin's phone key, and
     `phone_only_prefixes` back to its default (`/etc/`, `bin/`, `keys/`,
     `secrets/`), under which only phone-key approvers may install. The
     earlier rule that a unit serving HTML or JS on colinrozzi.com is
     phone-only is retired, and can come back the same way.
   - Run proposals (commands run as colin, SPEC-run) stay phone-only.
   - **The approve unit stays on colin's phone** (tova, 2026-11-17): its page
     holds his approver key and is what keeps run proposals phone-only, so
     code there approved by tova would undo that. It is its own
     service (serve-approve.wisp, :8084, Caddy sends the origin there), so
     nothing in the live unit can answer approve.colinrozzi.com; while that
     origin was served through live.wisp, the live unit could change it too
     (lux, 2026-11-17).
     The honest limit: that keeps a careless or tova-approved live change
     off the approve page, but is not yet a wall. Any service in the daemon
     can listen on 127.0.0.1:8084, so one that starts first could answer
     the origin (approve is listed first in config.toml, so a squatter must
     race a running service, and approve fails loudly); and config.toml,
     which names approve's start file, is the tova-tier config unit. The
     wall is the supervisor narrowing each child's tcp-listen to its own
     port with config on the phone (0130), or approve in its own daemon
     under its own user.
   - When 0130 removes agents' root on server3, approve and config
     must move to the phone tier in the same step, or 0130 closes nothing.
   - **Auto-approval** (beck): for a unit whose `deploy/<unit>.toml` says
     `auto = true`, the deploy workflow waits, after posting the request,
     for the merge commit's newest `check.result` signed by a current key of
     the `actions` or `checks` identity (as SPEC-pr 3 counts checks). On
     `pass` it signs the `deploy.approve` itself, as `runner.desktop`. On
     `fail`, `error` or no result in time, it approves nothing and a person
     must. It counts only where `runner.desktop`'s key is among the unit's
     approvers in the root copy and in its `deploy/approve/<unit>` rules
     line, so turning it on is those two lines plus `auto = true`. No unit
     has it yet.
   - **Before any unit gets `auto = true`** (lux), since then no person
     looks at the request:
     1. The request's commit MUST be master's: the deploy workflow fetches
        and refuses unless the commit is the tip of `refs/heads/master` on
        server3. Checks run on every branch push, so without this a branch
        with green checks would deploy unreviewed code.
     2. The bundle MUST be the commit's content: built from git (`git
        archive` or `git show <commit>:<path>`), never from a working tree,
        and a dirty tree is refused. Otherwise edits the checks never saw
        ship under a green commit.
     3. Later: the server3 runner rebuilds the deterministic tar from
        server3's bare repo at that commit and refuses a bundle whose
        sha256 differs, so even a wrong bundle from the desktop can't
        install.
     These matter less while tova approves each request by hand, after
     looking at it.
   - An approval by tova's key can be made by any agent on the desktop
     (SPEC-id 5). That is the honest note of choice (a).
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
   8. for each unit A in the request's `after`, with a `deploy.request` for
      the same env and the same commit: that request has a `deploy.done`. If
      it is still open or approved and not yet installed, the runner
      **waits** and checks again, without refusing. If it was refused or
      declined, it posts `deploy.refused` with "after A failed". A unit in
      `after` with no request at that commit (the merge didn't change it) is
      no constraint. Waiting stops at the request's own `expires`, when the
      runner posts `deploy.refused` with "after A not done before expiry",
      so nothing waits forever and the approver sees why. A request whose
      `after` chain, through the same merge's requests, comes back to its own
      unit is refused at once with "after cycle"; the deploy workflow also
      refuses such a cycle before it posts any request (lux).
   9. the request was asked against what is installed now, and goes back
      only as a true rollback. Only the host's runner knows what it
      installed, so this is the one check a stale or mislabelled request
      cannot pass (lux, ada, beck; after the 2026-11-17 backlog):
      - the runner keeps its own record of every version it installed, per
        unit and env (`done.json` in its root-owned state, written as it
        posts each `deploy.done`, field units too). It never rebuilds that
        record from the field's `deploy.done` events, which a key a
        registrar added could forge. If the record is lost, every request
        is refused as stale until a root step restores it;
      - the request's `installed <version> <commit>` (`0 -` when nothing is
        installed) must equal the newest version in that record and its
        commit. Otherwise: "stale: asked against version N, installed is
        version M". A request without `installed` is refused;
      - a request with `rollback V` passes this check only if V is in the
        record and the request's bundle is the bundle V installed.
        Otherwise: "the rollback label does not match version V";
      - any other request, when something is installed, must be a commit
        that is not an ancestor of the installed one. The runner asks the
        host's bare repo, as the repo's owner and never as root (`git
        merge-base --is-ancestor`), and an answer of older, or any failure
        to answer, refuses it: "older than what is installed … and not a
        rollback".

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
bundle that `deploy.done` version installed, and `age rollback`. A
`rollback` label whose bundle is not that version's is an ordinary request,
judged by its commit like any other (lux). It is approved and installed
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

**A version directory is written once, and never again** (lux):
- the runner refuses a request whose `units/<unit>/<env>/<n>/` already
  exists;
- it writes the bundle into a temporary directory beside it and renames it
  into place, so a half-written version is never visible;
- after that the directory is read-only to the service user: directories
  555, files the root copy's mode without write bits (444 by default).

A rollback to version V is then `deploy <unit> V` of a bundle still on
disk, after the runner checks that the files there still match the bundle
sha256 that V's `deploy.done` names. If an old version could change, "roll
back to V" would stop meaning the bundle that was approved. The request and approval stay as in section 6, so a rollback is still
one signed tap. In-place units (anything not run by a supervised child, such
as `/etc` files) keep the in-place install.

## 8b. Field-served units

A unit whose root copy says `layout = "field"` (ticket 0064, doc
`site-from-field`) is served from the field, not from files on the host:
- **Its paths.** Each is `file = "public/<path>"`: where web.wisp serves
  it, not a path on the host, and no owner or mode. Two field units never
  serve one path. The repo's `deploy/<unit>.toml` says `layout = "field"`
  too, so deploy-request takes `public/...` as its installed paths; the
  root copy decides.
- **Install.** The runner checks the bundle as a versioned one's (the
  approved sha256, regular files, normalized relative paths, each once,
  each the unit's) and each file at most 512 KB, then puts each file into
  its node as a blob (`put-blob`, SPEC-node 8.10). It writes nothing on the
  host and restarts nothing.
- **Done.** `deploy.done` is as for any unit, `<sha256> <path>` per file,
  with one more header, `layout field`. That event is the switch: web.wisp
  serves each path from the blob named by the newest `layout field`
  `deploy.done` of its unit (by `version`), and only from a `deploy.done`
  whose author is a current key of the host's runner identity
  (`runner.server3`). A newer `deploy.done` without `layout field` takes the
  unit's paths back to the host's files.
- **Rollback** is a rollback request as in 6: its files are already blobs,
  so the runner puts nothing new, and its `deploy.done` makes the older
  version the served one.
- **The limit, for now** (lux): web.wisp trusts a `deploy.done` signed by
  the runner's identity, not the approval itself, and under F3/F4 another
  key can be added to that identity or used from the daemon. So the root
  copy refuses `layout = "field"` for a unit whose approvers include a
  phone key, until web.wisp checks the `deploy.approve` against a
  read-only copy of the root copy's approvers.

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
