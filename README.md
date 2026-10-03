# skein-onboard

The onboarding app for a [skein](https://github.com/shruggr/skein) host:
installed in the **host skein** (the operator's own instance on a host), it
creates a skein for anyone with a wallet. The page sends one request over
its BRC-104 session; the app asks the host's **instance manager** for a new
instance from the default image, claimed for the caller's key, and answers
where it is. Version **0.1.0**.

## What it is

One program, `bin/onboard.wasm`, interface `onboard/1`, one function:

| function | args | answer |
|---|---|---|
| `onboard.create` (`writes: true`) | `{handle, image?}` | `{handle, identity, url}` |

It is reached on one http row, `POST /onboard/call`, sender `session`: any
key with a BRC-104 session (the page's wallet). The caller's key is the
owner of the new skein.

```
POST /onboard/call   {"fn": "onboard.create", "args": {"handle": "alice"}}
→ 200 {"fn": "onboard.create", "result": {"handle": "alice", "identity": "02…", "url": "http://alice.localhost:8100"}}
→ 409 {"fn": "onboard.create", "error": {"code": "refused", "message": "handle alice is taken"}}
```

What happens, in the host skein's log:

1. The route handler checks the body, applies the policy (free: no gating
   yet), records the request `{kind: "onboard-request", handle, owner,
   image?, request}` and launches a thread of this program on it. The
   client's connection is held until that thread comes to rest.
2. The thread emits `create {handle, owner, image?}` to the instance manager
   (the address book's role `manager`; only the host skein's address book
   has it, and the manager takes messages from the host skein only) and
   rests.
3. The manager derives the new instance's identity, boots it from the image,
   delivers the owner's claim, then publishes its hostname and starts it,
   and answers with a signed message: `{handle, identity, url}`, or
   `{error}` (the handle taken, a bad owner key, an image the host does not
   have).
4. The thread points the head `onboard/instances/<handle>` at that answer
   record (by reference, not a copy) and finishes; the handler answers the
   page.

Error codes: `bad-request` 400, `bad-args` 400, `not-admitted` 403 (no
session), `unknown-fn` 404, `refused` 409 (the instance manager said no),
`failed` 500 (the thread failed: for one, no instance manager in this
skein's address book, because the app is not in the host skein).
`src/main.zig` documents the contract in full.

## Use it

`skein-host init` creates the host skein; then the operator installs this
app into it:

```
skein-host install https://github.com/shruggr/skein-onboard#v0.1.0 --instance host
```

The manifest, `etc/app.json` (description left out):

```json
{
  "kind": "app",
  "name": "onboard",
  "version": "0.1.0",
  "programs": { "onboard": "bin/onboard.wasm" },
  "provides": [{ "interface": "onboard/1", "functions": {
    "create": { "writes": true, "args": { "handle": "string", "image?": "string" },
      "answer": { "handle": "string", "identity": "string", "url": "string" } } } }],
  "requires": [],
  "dispatch": [
    { "transport": "http", "address": "/call", "sender": "session", "program": "onboard", "fn": "call" }
  ]
}
```

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/onboard.wasm
zig build bin      # the same, into bin/onboard.wasm (committed; the build is reproducible)
zig build test     # the body's checks, the policy, the answers (natively)
```

skein runs this app end to end in `kernel-zig/equiv/host.ts` (a pinned
commit of this repo): `skein-host init`, the app installed in the host
skein, a client creating a skein, the child claimed for the client's key
and answering at its URL, the client installing an app in it, a second
create with the same handle refused, and both stores replayed.

## Docs

| what | where |
|---|---|
| the program's contract | `src/main.zig` |
| the host skein, the instance manager | skein `docs/ARCH.md`, `docs/MESSAGES.md` "The providers" |
| apps, manifests, install | skein `docs/APPS.md` |
| route handlers, a client waiting on a thread | skein `docs/MESSAGES.md` |

## Versions

| | |
|---|---|
| this app | 0.1.0 (tag `v0.1.0`) |
| skein-sdk | v0.4.0, by tag tarball and hash in `build.zig.zon` (`cbor`, `sk`, `app`, `dagjson`; no wallet) |
| skein | log format 8; skein's equivs pin this repo by commit |

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
