# Installing on the iPhone

No paid Apple Developer account, so there is no TestFlight. CI builds an
**unsigned** `.ipa`; Sideloadly signs it on Windows with a free Apple ID and
installs it over USB.

**The signature lasts 7 days.** After that the app refuses to launch and you
repeat steps 4–7. Takes about two minutes once set up.

## One-time setup

**1. Install Sideloadly** — [sideloadly.io](https://sideloadly.io), free.

Apple Mobile Device Support is already on this machine (checked), so you do
**not** need iTunes. That is normally the fiddly prerequisite.

## Every build

**2. Download the build.** Open the latest green **ios** run in
[Actions](https://github.com/Vinayak-Sutar/ios-app/actions), scroll to
**Artifacts**, download `AdvancedNotes-unsigned-ipa`. You must be signed in to
GitHub or the download link will not appear.

GitHub wraps artifacts in a ZIP, so **unzip it** — you want the `.ipa` inside,
not the `.zip`.

**3. Connect the phone.** Plug in, unlock, and tap **Trust This Computer** if
asked.

**4. Sideloadly.** Drag the `.ipa` into the window, enter your Apple ID email,
press **Start**.

- It will ask for your Apple ID password. With two-factor on, it may want a
  6-digit code, or an **app-specific password** from
  [appleid.apple.com](https://appleid.apple.com) under Sign-In and Security.
- Leave the bundle identifier alone (`app.advancednotes.app`). Changing it
  burns another of the 10 App IDs a free account gets per 7 days.
- A free account allows **3 sideloaded apps** at once.

**5. Trust the certificate.** On the phone: **Settings ▸ General ▸ VPN &
Device Management** → your Apple ID → **Trust**. Needed once per certificate,
so usually only the first time.

**6. Launch it.** Allow notifications when asked — reminders need it, and it
is the one capability a free account still gets (push would not be).

**7. Lower the cold start, first time only.** Close the app, then
**Files ▸ On My iPhone ▸ Advanced Notes ▸ _dev ▸ overrides.json** and set:

```json
"coldStartNotes": 5
```

Reopen the app. Without this, nothing files until note 21 — the default of 20
is the measured value from the Windows app, and the reason is real (an empty
vault has no centroids, so early notes would each invent a collection from
their own incidental wording). But it makes for a poor first run.

## Testing it

- Tap the **diag** capsule, bottom right, then **Run probes**.
- Back on **notes**, save about 8 short notes across two obvious topics — a
  few about one hobby, a few about another.
- Open **Files ▸ On My iPhone ▸ Advanced Notes** and read the `.md` files. The
  frontmatter shows the filing decision for each note, which with no debugger
  attached is the closest thing to a log.

### The number that matters

The **separation gap** on the diagnostics page. Above ~0.08 and auto-filing
should work; below ~0.02 and Apple's embeddings cannot cluster these notes,
which would mean rethinking the approach rather than tuning it.

Also worth reporting: the `availability` line, and the embedder's `dimension`
and `maximumSequenceLength` — nobody has published real iOS values for those.

## When it goes wrong

Nothing in this app has ever run, so expect something.

| What you see | What it means |
|---|---|
| Sideloadly refuses or errors | The known risk. Its maintainers claim iOS 27 works, independent reports conflict. Fallbacks: [SideStore](https://sidestore.io), LiveContainer, or paying the $99 |
| Blank white screen | The server did not come up, or `app.html` choked on a response. The **diag** button is native and should still work — that alone narrows it a lot |
| "Could not start" with a message | The server failed; the message is the reason, and it is selectable so you can send it |
| Everything lands in Inbox | Either step 7 was skipped, or the embeddings genuinely do not separate. The diag page distinguishes these |
| Works, then dies after a week | Normal. The signature expired; redo steps 4–7 |

On the diagnostics page, **Logs** dumps the app's own `OSLog` output. Paste
that and it is usually enough to work from.
