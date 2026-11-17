# Releases from tags: specification

Status: ticket 0155 step 6, 2026-11-17 (ivo; design in doc releases, reviewed
by lux and tova in branch git-platform-actions-and-deploys-as). A tag builds a
repo's artifacts on a runner. The files live outside the field, keyed by
sha256. An approver makes a release **latest**, and only a root-owned
updater moves it.

## 1. The tag

A release tag is made only at the tip of the repo's default branch on
server3: `lib/release ME tag REPO [TAG]`. Without TAG, the name comes from
`.actions/next-tag` at the tip. It is run with the commit, prints a tag or
nothing, and for wisp is wisp's next-release-tag rule. A tip that already
carries a tag is refused. The tag is annotated and pushed to server3, and
post-receive posts git.push for refs/tags/TAG as for any ref (SPEC-git 1).

## 2. The build

A workflow named `release` with `on = ["tag"]` (SPEC-actions 1) builds it on
the runner, which first checks that the tag's commit is an ancestor of the
default branch on server3, and builds nothing otherwise. A step lists its
`artifacts` (paths in the worktree, or results under /nix/store/). After
the job passes, the runner:
- reads each artifact once into a private copy, hashing it;
- puts it in the store with `release-put <sha256> <size>` (section 4);
- adds `artifact <name> <sha256> <size>` lines to action.result.

Names are the file's basename, `[A-Za-z0-9._-]{1,128}`, unique within a
job, and each artifact is at most 100 MB.

So that the build can be compared, a repo SHOULD build its artifacts from a
pinned flake package that any other builder (GitHub's Actions, another
machine) can build to the same bytes.

## 3. Events

| kind | scope | who signs | body |
|---|---|---|---|
| `release.request` | `release/<repo>` | the runner, as `actions` | `from actions`, `repo`, `tag`, `commit` (40 hex), `job` (the action.job id); a blank line; one `<name> <sha256> <size>` line per artifact |
| `release.approve` | `release/approve/<repo>` | an approver of the repo | `from`, `request` (its id), `repo`, `tag`, `commit`, optionally `rollback yes`; a blank line; the request's artifact lines, unchanged |

- A request's parent is its action.result. An approval's parent is its request.
- node-chat posts release.request (field/chat.wisp). An approval is signed in the approver's daemon session and admitted directly (`lib/release ME approve`), since node-chat writes nothing in release/approve/.
- A reader counts a request only if it is signed by a current key of id/actions. Under option (a), anyone can post one under any name, as with check.result (SPEC-pr 3).

Rules: `release/ id`; `release/approve/ none`; `release/approve/<repo> <approver key>`.

## 4. The store

`/var/lib/field-releases/sha256/<sha256>` on server3, owned by the `releases` user and written only through `release-put`. That is the forced command of the runner's upload key (`restrict,command="release-put"`):
- It reads the file from stdin.
- It stores the file only if the size and the hash match what was announced.
- It never replaces a file. Putting one that is already there is `ok`.
- It refuses an empty file, a file over 100 MB, and anything past a 10 GB quota.

Anyone holding the key can at worst fill the store up to its quota.

Caddy serves the store as static files. Wisp never serves these files.
- `/dl/<sha256>`: immutable.
- `/releases/<repo>/<tag>/<name>` and `/releases/<repo>/<tag>/APPROVAL`: the approval event file, as the node holds it.
- `/releases/<repo>/latest/`: the same, for the latest release.

These are public repos only. A private repo's files are listed but not served, until a login check sits in front of the store.

## 5. Latest

Only the root-owned updater on server3 (`lib/release-updater`, deploy_trust's pattern) writes `releases/<repo>/`. For each release.approve, it checks:
1. the approver's key is on the root copy's list for the repo (`/etc/field-releases/repos.toml`);
2. the signature (strict Ed25519, over the id);
3. the request: signed by a key on the root copy's builder list, with every header and artifact line equal to the approval's;
4. the tag's commit is an ancestor of the default branch in server3's bare repo;
5. every artifact is in the store, with that size and hash;
6. where the root copy names a GitHub repo, the GitHub release of the same tag has the same sha256 for every artifact;
7. the commit contains the current latest's commit (latest never moves backward), unless the approval says `rollback yes`.

It then writes `releases/<repo>/<tag>/` (links into the store, plus APPROVAL) and swaps `latest` to it in one rename. A failed check moves nothing and is logged. `--dry-run` prints what it would do.

## 6. Install

install.sh fetches `latest/APPROVAL`. It checks:
- the sha256 of the canonical text equals the id;
- the Ed25519 signature over the id's 64 ASCII bytes is by a key built into install.sh;
- the kind is release.approve and the repo is the expected one.

It then fetches the artifact and checks its size and sha256 against the body before installing it. GitHub's release of the same tag is the fallback, checked against the same approval.
