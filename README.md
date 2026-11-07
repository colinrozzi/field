# field

One network of content-addressed events. An event is a short text record,
signed by its author, whose id is the sha256 of its text. A **node** holds
events, keeps a log of what it has seen, answers requests over TCP, and copies
events from other nodes. The **field** is what connected nodes make.
Everything else is a reading of it: chat is the first.

Written in [Wisp](https://github.com/colinrozzi/wisp), run as sessions of a
[theater-repl](https://github.com/colinrozzi/theater-repl) daemon on
[Theater](https://github.com/colinrozzi/theater).

## What is here

| | |
|---|---|
| `SPEC-node.md` | the node: the event file byte for byte, scopes, admission, the seen chain, the TCP protocol, peers, the gate, conformance checks |
| `SPEC-chat.md` | chat on the field: event bodies, the model (branches, threads, state, tickets), conformance |
| `DESIGN.md`, `CHAT.md` | why it is shaped this way, and how it was built |
| `store.wisp`, `server.wisp` | a node: the store and its TCP server |
| `peer.wisp` | following another node with `pull` |
| `gate.wisp` | a node's public door: TLS and a signed challenge |
| `client.wisp` | posting to a node from Wisp |
| `chat.wisp` | the chat posting service (signs with the node's `chat` key) |
| `chatmodel.wisp` | the chat model, kept in files, for Wisp readers |
| `docmodel.wisp` | documents (sections, edits, comments) on top of it; SPEC-doc.md |
| `mailmodel.wisp` | each name's mailbox (events addressed to it, read marks) across every scope; SPEC-mailbox.md |
| `feed.wisp` | turns outside reports (GitHub, agent status) into events |
| `vectors/chat/` | chat test vectors, and `run`, which checks `chatmodel.wisp` against them on a throwaway daemon |
| `vectors/doc/` | document test vectors (`make` writes them), and `run` for `docmodel.wisp` |
| `vectors/mail/` | mailbox test vectors (`make` writes them), and `run` for `mailmodel.wisp` |
| `rules` | which keys may write which scopes |
| `desktop/`, `server3/` | the start files of a two-node deployment: a desktop that syncs both ways through a server's gate |

## Running a node

In a theater-repl daemon whose filesystem root holds this repo at
`experiment/field/` (the require paths say so, for now):

```
theater-repl new node
theater-repl eval node - < experiment/field/serve-field.wisp
```

or list `desktop/serve-field.wisp` as a boot-list `[[service]]` in the
daemon's config. A node listens on `127.0.0.1:7800`. Put a gate in front of
it before anything off the machine can reach it.

## Checking a reader

```
vectors/chat/run
```

Starts its own daemon on a free port with a temporary root, so it never
touches a running node.
