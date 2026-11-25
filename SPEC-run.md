# Approve-and-run: specification

Status: ticket 0112, 2026-11-15 (beck). From the design document
`approve-and-run` (decided, colin). The events, the rules and the page come
first, then the desktop's runner; server3's runner comes after its
hardening (ticket 0130).

An agent **proposes** a command for a host. Only colin **approves** it,
signing in his phone's browser with a key that never leaves it. The host's
**runner** runs exactly the approved text and posts what it printed. All of
it is in the field, scope `run/<host>`.

MUST, SHOULD and MAY are as in RFC 2119. Bodies are header lines, a blank
line, then text (SPEC-chat 4.1), with `from NAME` first. Times are ms since
1970. Hosts are `desktop` and `server3`.

## 1. Events

| kind | scope | author | body |
|---|---|---|---|
| `run.propose` | `run/<host>` | the proposer's identity key (rules `id`) | headers `from`, `host`, `expires`, `why`, `to colin`; blank line; the command |
| `run.approve` | `run/approve/<host>` | an **approver key** | headers `from colin`, `proposal`, `host`, `expires`, `command` |
| `run.decline` | `run/approve/<host>` | an approver key | headers `from colin`, `proposal`; blank line; the reason |
| `run.result` | `run/<host>` | the runner's identity key (`runner.<host>`) | headers `from`, `proposal`, `exit`, `stdout`, `stderr`, `cut`; blank line; stdout then stderr |

### 1.1 `run.propose`

```
from beck
host server3
expires 1794081600000
why install the new Caddyfile for 0130
to colin

systemctl reload caddy
```

- `host` MUST equal the scope's `<host>`.
- `expires` is when the proposal stops being approvable, by the runner's
  clock. lib/run writes the event's time plus 1 hour unless told otherwise,
  and refuses more than 24 hours.
- `why` is one line, at most 300 bytes.
- `to colin` puts it in colin's mailbox (SPEC-mailbox 2).
- **The command is the rest of the body, byte for byte**, after the first
  blank line. It is what the runner gives `bash -c`: no trailing newline is
  added or removed. It MUST NOT be empty and MAY be at most 8192 bytes.
- At most one parent: the event it grew from (its `cause`, a message or a
  ticket), when that event is in a scope every holder of run/ also holds, so
  never one in private/ (ticket 0184; DESIGN.md Scopes). The parent proves
  order only: the runner checks the approval, never the proposal's parent.

### 1.2 `run.approve`

```
from colin
proposal 5c0e…(64 hex)
host server3
expires 1794081600000
command 9f86…(64 hex: sha256 of the command's bytes)
```

- Its one parent is the proposal, so a node holds the proposal before the
  approval (SPEC-node 5, step 6).
- `host` and `expires` are copied from the proposal. `command` is the sha256
  of the proposal's command bytes, as lowercase hex.
- **The approval is the event's own signature.** The event's id hashes its
  canonical text, which holds the proposal id, the host, the expiry and the
  command's hash, and the approver key signs that id (SPEC-node 2.3, 2.4).
  The proposal id already covers the command, so the repeated fields are a
  second check. They also make the approval say what it approves without
  looking anything up.
- Changing the command makes a different proposal, with a different id and
  command hash. Approving it needs a new signature. Using an old approval
  again fails the runner's run-once check (section 4).

### 1.3 `run.decline`

`from colin`, `proposal <id>`, a blank line, then the reason (it may be
empty). Its one parent is the proposal. A declined proposal is closed. It
is signed like an approval, so an agent cannot close colin's queue for him.

### 1.4 `run.result`

```
from runner.server3
proposal 5c0e…
exit 0
stdout 12
stderr 0
cut no

hello world
```

- `stdout` and `stderr` are the lengths in bytes of the two parts of the
  text, in that order.
- `exit` is the exit code, or `timeout` or `refused`.
- A refused run (section 4) puts the reason in stderr.
- A node takes bodies of up to 16384 bytes (SPEC-node 2.1). So the two parts
  are cut to fit together: stdout keeps at most 8192 bytes, and stderr the
  rest. `cut yes` says something was cut. The full output stays in the
  runner's log on the host.
  - The design said 64 KB each. The node's limit doesn't allow that.
- Its one parent is the approval.

## 2. Rules

```
run/ id
run/approve/ <approver key>
```

- `run/ id` lets any identity propose, and a runner post results, each
  signed as itself (SPEC-id 3).
- `run/approve/` is longer, so it decides alone for approvals and declines.
  It lists the approver keys only: **no key on the desktop**. Every session
  in the desktop daemon can sign with every key there (SPEC-id 5, the
  honest limit), and agents run shell commands as colin.
- Until colin registers a key, the line is `run/approve/ none`. `none` is
  no author's key, so the scope is closed.
- The desktop's rules file is colin's, so agents can edit it. The rules
  there keep honest mistakes out. The real checks are server3's node rules
  (installed by deploy, which agents can't reach once 0130 is done) and the
  runner's own list of approver keys (section 4).
- **A refusal stops a peer's sync.** If an agent got a forged approval into
  the desktop's store, server3 would refuse it, and desktop-to-server3
  copying would stop until it was dealt with (SPEC-node 9.2). That is loud,
  which is what we want.

## 3. The approver key

- It is a WebCrypto Ed25519 key made in colin's phone browser by the page
  (`/personal/run`, "Set up this device"):
  `generateKey({name: "Ed25519"}, false, ["sign", "verify"])`.
  - The private key is non-extractable. The `CryptoKey` lives in that
    browser's IndexedDB (database `field-approver`), and nothing can read
    its bytes out, the page included.
  - The page shows the public key, 64 lowercase hex.
- Registering it is done by hand, on purpose:
  1. `lib/chat colin id-add colin KEY phone`, so readers know it is
     colin's.
  2. Put it in the rules as `run/approve/ KEY`, on both nodes (deploy for
     server3).
  3. Put it in each runner's config.

  A second device (the laptop) is a second key, added the same three ways.
- To sign, the page builds the approval's canonical text (SPEC-node 2.2),
  takes its id, signs the 64 ASCII bytes of the id, and posts `sig` and text
  to `/personal/live/admit` (section 5).
- Losing the phone: take the key out of the rules and the runner configs,
  and retire it in `id/colin`.

## 4. The runner

One per host. **The desktop's is built**: experiment `lib/runner`, which
`sudo lib/runner-install` copies to `/etc/field-runner/` (root-owned) and
runs as colin from a system unit in `/etc/nixos/configuration.nix`. server3's own comes after
ticket 0130. Until then, a command for server3 is proposed for the desktop
as `ssh server3 ...` (tova, 2026-11-16).

The runner follows `run/approve/<host>`. For each `run.approve` it runs the
proposal only if all of these hold:

1. The approval's author is in the runner's own list of approver keys, and
   the event's signature checks (SPEC-node 2.4).
   - On the desktop, the list is `/etc/field-runner/approvers` (root's).
   - On server3 it will be a root-owned file under `/etc`.
2. The runner holds the proposal, and the proposal is both the approval's
   `proposal` and its one parent. The proposal's scope is `run/<this host>`,
   and its `host` is this host.
3. The approval's `host`, `expires` and `command` match the proposal.
   `command` is the sha256 of the command's bytes as the runner reads them.
4. The runner has not run that proposal before. It keeps the ids it ran,
   and records each one before running it, so a crash never runs a proposal
   twice. A `run.result` for the proposal in the field (other than `exit
   refused`) also counts, so losing that record doesn't run it again.
5. Now is before `expires`.
6. The runner holds no `run.decline` for the proposal. A decline at any
   time closes it.

It runs the command with `bash -c`, with no stdin, a 10-minute timeout, in
the user's home directory. Then it posts `run.result` as its own identity,
`runner.<host>`, through node-chat. A failed check posts `run.result` with
`exit refused` and the reason in stderr, once per approval. Every run and
refusal goes in its log, and the full output in `log/<proposal>.out` and
`.err`.

The desktop runner runs as colin, which agents already are. It does what a
terminal `!` step does, from the phone. Everything it **trusts** is out of
colin's user's reach, and so out of agents' reach (tova's review):

- its code, a root-owned copy;
- its approver list, root's;
- its unit, in root's NixOS configuration.

Updating it is `sudo lib/runner-install` again, a step for colin.

What it **keeps** is colin's: its state and the field store. So an agent
can stop it, hide a decline, or break its runs. It can't make a run,
because every run needs an approval signed by a listed key, and those keys
are in colin's phone.

## 5. Writing from the page

`POST /personal/live/admit` (site/live.wisp) takes a body
`sig <128 hex>\n<canonical text>`, the event file (SPEC-node 2.5). It needs
the login. It relays only `run.approve` and `run.decline` in `run/approve/`,
and passes them to the node's `admit` (SPEC-node 8.6). The node checks the
signature and the rules. The answer is the id, or `400` with the node's
reason.

live.wisp does not sign. It can't make an approval, only pass one on.

## 6. State, as a reader works it out

A proposal is:

- **open** until it expires, with no decline or approval;
- **declined** once a `run.decline` for it is admitted;
- **approved** once a `run.approve` for it is admitted, and **done** once a
  `run.result` for it is;
- **expired** when open past `expires`.

`lib/run list` and colin's queue show open proposals, newest first.
