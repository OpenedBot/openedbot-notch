# openedbot notch

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple)
![Status](https://img.shields.io/badge/status-prototype-orange)

A prototype macOS notch UI for [openedbot](https://openedbot.app): your bots live in a small
black notch attached to an edge of the screen. One ring per bot shows who is working and how far
along the run is, who is waiting for your approval, and which runtime went down. Hover for details,
click to open the agent window: read the thread, approve or deny, reply. No need to open the console.

> **Status: prototype.** Out of the box it runs on **mock data**: ten demo bots in three sections,
> two scripted runs that loop, and a runtime that drops. It is not a supported openedbot product.

| Sections, one tray per pile | Bot card (hover) | Agent window (click) |
|---|---|---|
| ![](docs/sections-tray.png) | ![](docs/card.png) | ![](docs/dialog.png) |

## Where it fits

| Component | Role |
|---|---|
| **openedbot-notch** (this repo) | Prototype macOS notch UI, runs standalone on mock data |
| openedbot desktop app ([`apps/desktop`](https://github.com/OpenedBot/openedbot/tree/main/apps/desktop) in OpenedBot/openedbot) | Embeds this bundle on macOS and runs it in hosted mode |
| openedbot console | The web console the notch can optionally sign in to |
| edge-setup | Host-side installer and connector for the agents openedbot drives |

## Features

- **One ring per bot**: avatar in the centre, run progress as an arc coloured by state
  (running, awaiting approval, completed, runtime offline), amber badge when an approval waits.
- **Hover card**: bot, runtime, model, permission mode, routines, current runs, pending approval
  with *Deny* / *Allow once*.
- **Agent window**: thread (messages, tool calls), inline approval, composer. One window per agent.
- **Many bots**: bots waiting for approval are promoted; sections collapse into piles that expand
  into a tray on hover; an "active only" mode.
- **Announcements**: the notch opens briefly and plays a sound when a run finishes, a bot waits,
  or a runtime drops.
- **YOLO badge** (signed in, camera-notch island): a red `YOLO` badge and a countdown while a
  YOLO lease auto-approves a bot's writes on the host, and *Turn YOLO off everywhere* in the
  expanded island. See [YOLO leases](#yolo-leases).
- **Update badge** (hosted, camera-notch island): a blue dot in the compact island when openedbot
  has an update *ready* or *required*, and an *Update ready* / *Update required* row in the
  expanded island that opens openedbot on its update settings. See
  [Embedding in the desktop app](#embedding-in-the-desktop-app).
- **First sign-in demo** (hosted): when openedbot asks (`demo`), a scripted 12-second loop with
  two fictional bots, *Recherche* and *Rédaction*, and no network: both work, an approval unfolds
  the island with *Autoriser* / *Refuser* answered locally, both finish. It loops until the user
  touches it, then stops at the end of the cycle. See
  [Embedding in the desktop app](#embedding-in-the-desktop-app).
- **Menu bar item**, four screen edges, settings window, English and French UI.
  Hosted, the notch defaults to the island around the camera (`top`), on the screen that has the
  camera (the built-in one when open, else the main screen), and is re-placed on wake.

An interactive HTML mockup of the design lives in [`design/index.html`](design/index.html)
(open it in a browser, no build needed).

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 16+; developed with Xcode 27 / Swift 6.4)
- No third-party dependencies

## Quick start

```sh
make dev     # swift run OpenedbotPopup (fastest loop, no .app bundle)
make test    # swift test
make run     # release build, bundle dist/OpenedbotPopup.app, open it
```

`make build` / `make bundle` sign the binary with a local self-signed identity created by
`scripts/dev-sign.sh` (stored in a dedicated keychain under `~/Library/Keychains`), so the
Keychain does not prompt again after every rebuild. The first run asks macOS to trust that
certificate for code signing. The app has no Dock icon (`LSUIElement`): use the notch and the
menu bar item.

| Command | What it does |
|---|---|
| `make dev` | `swift run OpenedbotPopup`, no `.app` bundle |
| `make build` | Release build, signed with the local dev identity |
| `make bundle` | Build `dist/OpenedbotPopup.app` |
| `make run` | Bundle and open the app |
| `make test` | `swift test` |
| `make clean` | Remove build artefacts |

## Connecting to openedbot (experimental)

Without an account the notch shows the demo bots. *Settings › Account* can sign in to an
openedbot server (default origin `https://openedbot.app`, HTTPS only except local/lab hosts)
with the native PKCE flow; the session is kept in the macOS Keychain, never in `UserDefaults`.
This path is experimental and not guaranteed to work against current servers.

### YOLO leases

openedbot's YOLO mode issues signed, time-limited leases that auto-approve a bot's writes on the
host. When signed in (standalone or hosted), the notch reads them with the same client as the
feed (bearer token, `X-OpenedBot-Organization`, one replay after a 401) and shows them in the island:

- **Compact island**: a red `YOLO` badge and the time left (`m:ss`, `h:mm:ss` past an hour) as
  soon as one lease is active, even with no bot working.
- **Expanded island**: the number of active leases, what the displayed lease covers (whole
  runtime, a bot, a thread of a bot), and *Turn YOLO off everywhere*. The button asks for an
  inline confirmation, then calls the kill route. A `403` says only owners and admins can do
  it; any other failure is shown in the strip and written to *Settings › Journal*.

The contract the notch reads (the reference is `apps/desktop/README.md` in OpenedBot/openedbot):

| Route | Notch behaviour |
|---|---|
| `GET /api/organization/yolo/leases` | Polled every 30 s, and again just after the soonest `expiresAt`. `404`: the server has no YOLO, nothing shown. Other failures keep the last known leases (minus the expired ones) rather than hiding YOLO. |
| `POST /api/organization/yolo/kill` | Body `{}`, response body ignored. Success clears the badge, then the leases are read again: the server has the last word. |

Lease parsing is tolerant (`Sources/OpenedbotPopup/Model/Yolo.swift`):

- The response is `{ "leases": [...] }`, `{ "items": [...] }` or a bare array; an element that is
  not an object is skipped, not the whole response.
- Each lease reads `leaseId` (or `id`), `scope` (`thread`, `bot`, `runtime`, case-insensitive;
  anything else counts as an active lease of unknown scope), `botId`, `threadId`, `runtimeId`,
  `expiresAt`. Other fields are ignored.
- `expiresAt` is ISO 8601 (with or without fractional seconds, `Z` or an offset) or an epoch, as
  a number or a numeric string. An epoch of 10^11 or more is read as milliseconds, otherwise
  as seconds (10^11 seconds is the year 5138, 10^11 milliseconds is 1973). A missing or
  unreadable `expiresAt` keeps the lease active with no countdown, until the server drops it.
- The badge shows the lease that ends **last** (YOLO stays on until then); a lease with no
  deadline wins; on a tie, the broadest scope (runtime, bot, thread), then the lease id.
- The countdown runs against the server's `expiresAt` using the Mac's clock (no skew
  correction) and is rounded up: `0:01` until the last second, then the lease drops.

The demo (signed out) never shows YOLO. The hosted-mode protocol is unchanged.

The executable and module are still named `OpenedbotPopup` internally (bundle id
`app.openedbot.popup`), because the openedbot desktop app embeds the bundle under that name and
launches it with `--hosted`.

### Embedding in the desktop app

The desktop app's `make package-mac` (in OpenedBot/openedbot) looks for this repository's bundle in
a checkout next to its own, `../openedbot-notch` from its root (`NOTCH_DIR=/path/to/openedbot-notch`
otherwise):

```sh
make bundle    # dist/OpenedbotPopup.app, with OpenedbotHostedProtocol 1 and OpenedbotHostedFeatures in its Info.plist
```

The hosted-mode protocol (`Sources/OpenedbotPopup/Host/HostProtocol.swift`) mirrors the desktop
host, which is the reference: the Tauri shell's
[`apps/desktop-tauri/src-tauri/src/popup.rs`](https://github.com/OpenedBot/openedbot/blob/main/apps/desktop-tauri/src-tauri/src/popup.rs)
(and the Electron shell's
[`apps/desktop/src/shared/popup-protocol.ts`](https://github.com/OpenedBot/openedbot/blob/main/apps/desktop/src/shared/popup-protocol.ts)).
Change both sides together.

Host → popup messages are `hello`, `token`, `signedIn`, `signedOut`, `updateState`, `demo` and
`endDemo`; popup → host messages are `ready`, `token`, `openConsole`, `signOut`, `fatal` and
`demoEnded`. A message type the popup does not know is logged and ignored, so the host can add one
without a protocol bump.

The demo was added within v1 the same way. `ready` announces what the popup can do beyond v1,
`{"type":"ready","protocol":1,"version":"1.0.0","features":["demo"]}`, and the bundle declares the
same list (`OpenedbotHostedFeatures` in its Info.plist) so that the host knows before launching it.
The host sends `{"type":"demo","cycles":0}` only to a popup that announced it, right after `hello`
and before `signedIn`, so the real bots never show first; `cycles` is how many loops before it stops
by itself (0: until the user touches it). Stopped by itself, the demo keeps its last frame and
sends `{"type":"demoEnded"}`; `{"type":"endDemo"}` brings the session's bots back. The demo's
fictional bots open nothing in the console.

`updateState` is the app's update status, sent on every change and once after `hello` +
`signedIn`/`signedOut`:

```json
{"type":"updateState","status":"ready","version":"1.0.4"}
```

`status` is 1 to 32 lowercase letters (`idle`, `checking`, `available`, `downloading`, `ready`,
`installing`, `error`, `required`; any other word shows nothing); `version` is absent, `null`, or 1
to 32 digits and dots (the downloaded version for `ready`, the minimum for `required`). Anything
else drops the line. Only `ready` and `required` show the badge; the state survives `signedOut`
and is cleared when the host closes stdin. Clicking the row sends
`{"type":"openConsole","path":"/settings/updates"}`; the notch never installs or restarts anything.

## Configuration

No environment variables are needed to run it. In the app, *Settings* has pages for General, Account, Models, Journal,
Notch, Menu bar, Announcements and Demo. For tests, `OPENEDBOT_SNAPSHOT_DIR` enables the
PNG snapshots (see [Testing](#testing)).

## Testing

```sh
make test                                                  # swift test
OPENEDBOT_SNAPSHOT_DIR=/tmp/notch-ui swift test --filter Snapshot  # render views to PNG, no windows
```

## Project structure

```text
Sources/OpenedbotPopup
├── App/     entry point, app delegate, menu bar, settings pages
├── Auth/    native sign-in client, Keychain session, token sources
├── Design/  metrics, palette, typography, Markdown rendering
├── Feed/    REST + SSE client, DTOs, mapping to notch models
├── Host/    hosted-mode stdio protocol
├── Model/   domain models, geometry, layout rules, mock feed
└── Notch/   notch panel, rings, cards, agent window
Tests/OpenedbotPopupTests   unit tests (geometry, layout rules, mock feed, auth, host protocol, YOLO leases, update badge)
Resources/            Info.plist, bot artworks, faces, provider marks
design/               static HTML mockup
```

## Documentation

- Website: <https://openedbot.app>
- Documentation: <https://docs.openedbot.app>

## Contributing

This is a prototype published for reference. Issues and pull requests are welcome; please keep
changes small and run `make test` before opening one. Every pull request and push to `main`
is scanned by gitleaks (`gitleaks git . -c .gitleaks.toml`).

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Kévin Aubrée.

Provider logos in `Resources/brand-marks.json` come from [Simple Icons](https://simpleicons.org)
(CC0-1.0); the brands themselves belong to their owners.
