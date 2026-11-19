# Advanced Notes — iPhone

A native iPhone app for [Advanced Notes](https://github.com/Vinayak-Sutar/advance-notes-app),
running on Apple's on-device model instead of Ollama, with no connection to the
Windows version.

This is an **MVP**. It exists to answer two questions:

1. Can an app be built and installed from Windows, with no Mac and no paid
   Apple Developer account?
2. Do Apple's on-device embeddings file notes well enough to feel like magic
   rather than a mess?

## How it is put together

The interface is **not rebuilt**. The Windows app's `mnemo/web/app.html` is one
self-contained 5,811-line file with a complete phone layout already in it, and
it talks to its backend only through relative `fetch('/api/…')` calls. So this
app ships that page unchanged inside a `WKWebView` and replaces the Python
server underneath it with Swift.

That inverts the hardest part of a native port. Rebuilding the UI in SwiftUI
would have been months of work written blind — no Simulator, no previews, no
debugger on a Windows machine. Instead the UI stays editable and testable in an
ordinary browser against the Python server, and only the bridge is written
blind.

```
Sources/NotesCore/     pure Swift, no dependencies, no Apple frameworks
                       -> builds and tests on Windows, in seconds
App/AdvancedNotes/     the bridge: HTTP server, embedder, model, vault
                       -> written blind, kept thin, verified on the phone
App/project.yml        the Xcode project is GENERATED from this, never committed
```

`NotesCore` holds the two things most likely to be quietly wrong — the
frontmatter codec and the vector maths — precisely because they are the two
that can be checked locally.

## The local loop

```bash
swift test
```

That is the whole inner loop, and it covers the frontmatter codec, the vector
maths, the slug rules and the routing decisions. It needs the Swift toolchain:

```bash
winget install --id Swift.Toolchain -e --source winget
```

Swift on Windows also needs **Visual Studio Build Tools** with the Windows SDK;
the Swift installer will say so if they are missing. CI pins the same toolchain
version, so keep them in step.

The `Tests/NotesCoreTests/Golden/demo-vault` fixtures are real notes copied from
the Windows app. The important test asserts that re-rendering one produces
**byte-identical** output — if that fails, the two apps disagree about the note
format and the vault is not portable after all.

## Building and installing without a developer account

There is no TestFlight here, so the loop is: CI builds an unsigned `.ipa`, and
Sideloadly signs it on Windows with a free Apple ID.

1. Push to `main`, or run the **ios** workflow by hand.
2. Download the `AdvancedNotes-unsigned-ipa` artifact from the run.
3. Open [Sideloadly](https://sideloadly.io) on Windows, plug the iPhone in,
   drop the `.ipa` in, enter the free Apple ID, press Start.
4. On the phone: **Settings ▸ General ▸ VPN & Device Management** ▸ trust the
   developer certificate. Needed once per certificate.

Things to know about the free tier:

- **The build expires after 7 days.** Re-signing is the same two minutes.
  [SideStore](https://sidestore.io) can refresh on-device over Wi-Fi without the
  PC and is worth trying, though its iOS 27 support is reported as partial.
- Limits are 10 App IDs per 7 days and 3 sideloaded apps at once — hence one
  bundle id and one target.
- No push notifications. Harmless: reminders are *local* notifications, which
  need no entitlement.
- No Private Cloud Compute (it needs a managed entitlement plus Small Business
  Program enrolment), so there is no cloud fallback. The point is the on-device
  model anyway.
- App Groups may not provision, which would rule out a share extension and
  widgets. Both were out of scope for the MVP.

None of this is permanent. Paying the $99 later swaps Sideloadly for TestFlight
and changes no application code.

## The diagnostics page

With no debugger, the app has to explain itself. The first screen is a
diagnostics page reporting:

- `SystemLanguageModel.default.availability`, in Apple's own words — that enum
  is the only error message the framework ever gives
- the embedder's `dimension` and `maximumSequenceLength`, **read at runtime**;
  Apple documents these properties without publishing their values, and they
  differ between iOS and macOS, so nothing here is hardcoded
- a storage round trip: write a note, read it back, compare
- **the separation probe** — six short notes in two obvious topics, reporting
  mean similarity within a topic against across topics

That last one is question 2 in miniature. If the gap is not clearly positive,
no threshold will make auto-filing work, and it is much better to know that in
week one than in week eight.

`Run probes` also exercises one real model round trip, and `Logs` reads the
app's own `OSLog` output back out of the process.

## Notes on the vault

Notes are `Documents/Vault/<Collection>/<slug>.md` with the same frontmatter the
Python app writes, so the two are interchangeable. With `UIFileSharingEnabled`
set, the vault appears in the Files app under *On My iPhone ▸ Advanced Notes* —
which keeps the product's promise that notes are plain files, and doubles as the
inspection window a debugger would otherwise provide. The filing decision for
any note can be read straight off its frontmatter.

To check the format really is portable, copy the vault into
`D:\temp\mnemo\profiles\<id>\` and run `python -m mnemo rebuild`.
