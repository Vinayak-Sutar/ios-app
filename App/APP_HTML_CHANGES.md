# How this copy of `app.html` differs from the Windows app's

`app.html` is vendored from `mnemo/web/app.html` in the Windows project and was
kept byte-identical on purpose: the whole interface comes free, and the UI can
still be developed and tested on Windows in a browser against the Python
server.

It is no longer byte-identical. Four strings diverge, all of them sentences
that are simply untrue on a phone — there is no laptop here, no graphics card
to report, no model to download, and nothing to pair with over Wi-Fi.

This file lives beside `project.yml` rather than in `Resources/`, which is a
bundled folder: a note to ourselves does not belong on the phone. It exists so
that re-vendoring a newer `app.html` does not silently
throw them away. After copying a new version in, re-apply these four.

## The divergences

All four are wording only. No behaviour, no API, no layout.

1. **Settings → AI, the heading paragraph** (`aiTab`)
   - was: "All of the AI runs on this computer. This one has …GB of graphics
     memory and …GB of memory, so **X** suits it. Now using **Y**."
   - now: "All of the AI runs on this iPhone, which has …GB of memory. Nothing
     you write leaves the device. Now using **Y**."
   - why: the phone reports no `gpu_gb`, and there is one engine, so the
     "which profile suits this machine" sentence has nothing to say.

2. **Settings → AI, the models section** (`aiTab`)
   - was: "Models on this computer" / "…GB in the app's own folder. Models in
     use can't be removed; removing the others frees the space."
   - now: "What's doing the thinking" / "Both of these come with the phone, so
     there is nothing to download and nothing to remove."
   - why: nothing was downloaded. The model and the embedder are part of iOS.

3. **Settings → the pairing panel** (`phoneSection`)
   - was: "Your phone" / "Start Notes from the desktop shortcut to use it on
     your phone over Wi-Fi."
   - now: "This device" / "Everything is on this iPhone: your notes, the filing
     and the AI. There is nothing to connect to."
   - why: this *is* the phone. There is no laptop serving it.

4. **Settings → AI, when the engine is unavailable** (`aiTab`)
   - was: "The AI isn't running" / "Notes still works. Start the app again to
     bring the AI back."
   - now: "Apple Intelligence isn't ready" / "Notes still works, and files what
     it can. Check iOS Settings → Apple Intelligence & Siri, or give it a while
     if it is still downloading."
   - why: restarting the app is the remedy for a stopped Ollama. Here an
     unavailable model means Apple Intelligence is switched off or still
     fetching its assets, and neither is fixed by reopening the app.

## What is still identical

Everything else: every screen, all 18 palettes, the 17 fonts, the phone
layout, and every `fetch('/api/…')` call. The bridge is written to the page's
contract, not the other way round, so a newer `app.html` should drop in and
work.
