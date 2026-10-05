# skein-onboard

The onboarding app for a [skein](https://github.com/shruggr/skein) host:
installed in the **host skein** (the operator's own instance on a host), it
gives anyone with a wallet a place on the host, and it is the host's
**BRC-169 server**. A page with a BRC-104 session gets a skein of its own; a
wallet that signs a registration gets a mailbox instance and a handle
certificate. Every handle the host certifies is recorded here; resolve,
search and the manifest are answered from those records. The app asks the
host's **instance manager** for every instance and the host's **certifier**
for every signature; it holds no key. Version **0.2.0**.

## What it is

One program, `bin/onboard.wasm`, on six rows (installed under `/onboard/`):

| route | sender | body / query | answer |
|---|---|---|---|
| `POST /onboard/call` | `session` | `{fn: "onboard.create", args: {handle, image?}}` | `{fn, result: {handle, identity, url}}` |
| `POST /onboard/register` | `*` | `{username, identityKey, signature}` | `{handle, domain, identityKey, messagebox, certificate, keyringForSubject}` |
| `POST /onboard/profile` | `*` | `{handle, record, signature}` | `{handle, profile, displayName?, avatarURL?}` |
| `GET /onboard/resolve` | `*` | `?handle=<handle>[@<domain>]` | BRC-169 §5.2 |
| `GET /onboard/search` | `*` | `?q=&limit=` | BRC-169 §5.6 |
| `GET /onboard/manifest.json` | `*` | | BRC-169 §5.1 |

The host's router maps its own origin onto the open rows (skein
`docs/MESSAGES.md`, "BRC-169 is discovery"): `/manifest.json`,
`/.well-known/metanet-handles/resolve` and `/search`, `POST
/account/register` and `POST /account/profile` reach this app in the host
skein, each request an entry in its log.

### Configuration

`config.onboard` in the installed manifest, written at install
(`skein-host install … --config '{"onboard": {…}}'`):

| key | meaning |
|---|---|
| `domain` | the one domain this host's handles are at, `<handle>@<domain>` (default `localhost`) |
| `origin` | the host's own origin, where the manifest says resolve and search are (default `https://<domain>`) |
| `name`, `note`, `icon` | the host's presentation in `metanet.trust` (each optional) |
| `ordfs` | the ORDFS content route an avatar's URL is derived under (default `https://api.1sat.app/content`; empty: none) |

### Registering (`POST /onboard/register`)

The body: `username` (a host name label), `identityKey` (hex), and
`signature` (hex DER): the key's `createSignature` under
`[2, "skein register"]`, key ID the username, counterparty `anyone`, over
the UTF-8 text `register <username>@<domain>` — the domain is this host's
(`config.onboard.domain`, which the router also answers at
`/.well-known/skein-host`), so a registration signed for one host is not
good at another.

1. The route handler checks the body (400), the signature (401), the name
   (409: reserved — `id`, `host` — or another key's), and that the key holds
   no other handle here (409: one key, one handle). It records the request
   and launches a thread; the client's connection is held until the thread
   comes to rest.
2. The thread emits `create {handle, owner: <the key>, image: "mailbox",
   domain}` to the instance manager (unless the key holds this handle
   already) and rests. The manager creates the mailbox instance and answers
   `{handle, identity, url}` (or `{error}`: the handle is an instance's,
   409). The answer is recorded under `onboard/instances/<handle>`.
3. The thread puts the **issuance record** `{kind: "handle-issuance",
   handle, domain, subject, messagebox, issuedAt, request, prev?}` and emits
   `issue {handle, domain, subject, serialNumber, issuance}` to the
   certifier. The serial number is base64 of the issuance record's SHA-256
   (the digest its CID names): every issue has its own, a re-registration
   included.
4. The certifier answers `{certificate, holder: {certificate,
   keyringForSubject}, serialNumber, issuance}`: the plaintext certificate a
   resolver checks and the holder's copy (BRC-52 encrypted fields and the
   keyring a wallet's `acquireCertificate` takes). The thread writes the
   **certificate record** `{kind: "handle-certificate", handle, domain,
   subject, messagebox, issuedAt, serialNumber, issuance, prev?,
   certificate, holder}`, moves `onboard/handles/<handle>` to it (its `prev`
   the record before: the trail of every issue) and the index
   `onboard/index` (`handles`: handle → record; `keys`: key → handle), and
   answers the page the holder's copy.

The same key and name again: the mailbox stands, a new certificate is
issued under a new serial (a wallet that removed the old one can take it).

`onboard.create` goes the same way with the default image: the manager
creates the skein claimed for the session's key, and the new instance's
handle is certified for the instance's own identity.

### The profile (`POST /onboard/profile`)

`record`: base64 of the DAG-CBOR `{domain, name?, avatar?}` (`@1sat/utils`
`encodeProfile`; `avatar` a 36-byte outpoint); `signature`: hex DER by the
handle's key under `[1, "metanet handles profile"]`, key ID `1`,
counterparty `anyone`, over those bytes. Checked (401 another key; 400 not
this domain or not the shape; 404 no such handle) and kept under
`onboard/profiles/<handle>`; resolve and search serve it with
`displayName` and `avatarURL`.

### Error codes of `/onboard/call`

`bad-request` 400, `bad-args` 400, `not-admitted` 403 (no session),
`unknown-fn` 404, `refused` 409 (the instance manager said no), `failed`
500 (the thread failed: for one, no instance manager or certifier in this
skein's address book, because the app is not in the host skein). The open
routes answer `{error}` (register, profile) or §5.3's `{metanetHandles,
error: {code, message}}` (resolve).

`src/main.zig` documents the contract in full.

## Use it

`skein-host init` creates the host skein (the instance manager and the
certifier in its address book); then the operator installs this app into
it:

```
skein-host install https://github.com/shruggr/skein-onboard#v0.2.0 --instance host \
  --config '{"onboard": {"domain": "skein.nexus"}}'
```

A host skein made before the certifier was in the host skein's address
book needs its entry: `skein-host peers host add <certifier key> certifier
--transport local --role certifier` (the key: the manifest's
`metanet.trust.publicKey`, `providerKey("certifier")`).

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/onboard.wasm
zig build bin      # the same, into bin/onboard.wasm (committed; the build is reproducible)
zig build test     # the bodies, the signatures (vectors from @bsv/sdk), the queries, the answers (natively)
```

skein runs this app end to end: `src/host/router.test.ts` and
`src/host/handles.test.ts` (registration, the certificate records,
resolve, search, the profile) and `kernel-zig/equiv/host.ts` (`skein-host
init`, the app installed, a client creating a skein, it resolving with its
certificate), at the commit pinned in `src/testapps.ts`.

## Docs

| what | where |
|---|---|
| the program's contract | `src/main.zig` |
| the host skein, the instance manager, the certifier | skein `docs/ARCH.md`, `docs/MESSAGES.md` "The providers" |
| registration and BRC-169 | skein `docs/MESSAGES.md` "Mailbox instances", "BRC-169 is discovery" |
| apps, manifests, install | skein `docs/APPS.md` |

## Versions

| | |
|---|---|
| this app | 0.2.0 (tag `v0.2.0`) |
| skein-sdk | v0.4.0, by tag tarball and hash in `build.zig.zon` (`cbor`, `sk`, `app`, `dagjson`, `secp`; no wallet) |
| skein | log format 8; skein's tests pin this repo by commit |

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
