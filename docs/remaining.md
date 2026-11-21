# What is left to build

As of run #27. Ordered by what would change the app most, not by effort.

The route count understates it: 34 of the 47 routes `app.html` calls are
answered, but the real gaps are behavioural, not endpoints.

## 0. Decide whether filing can work at all

**Blocking everything below it**, because the rest is only worth building on a
foundation that works.

Measured on device: unrelated notes score **0.840**, related ones **0.896**. A
gap of 0.055, with the whole useful range squeezed into the top sixth of
cosine. Thresholds have been moved to 0.820 / 0.865 / 0.012 to match, but that
is accommodating the problem rather than fixing it.

Run #27 measures whether **centring** — removing the mean direction every
mean-pooled vector shares — widens that gap. Three outcomes:

- **Gap becomes ~0.2+**: apply centring in routing, store the corpus mean
  beside the vectors, recalibrate once more. Filing is viable.
- **Gap improves but stays small**: viable with a high Inbox rate, which the
  Python app argues is the right trade anyway — a note in Inbox is one tap
  from filed, a misfiled note is invisible.
- **No improvement**: `NLContextualEmbedding` cannot carry this. Options then
  are a bundled Core ML sentence embedder, an MLX model, or asking the
  language model to name a collection and dropping similarity from the
  decision.

### Then: a real calibration harness

Six sentences is a measurement, not a calibration. The Python app derives
thresholds from a 500-note corpus with known topics and measures purity,
coverage and sprawl. Porting `corpus.py` and `calibrate.py` into `NotesCore`
makes that runnable on Windows **once the embedding matrix has been exported
from the phone** — about 1 MB, and then the device is out of the loop
permanently.

## 1. Images

`/api/upload` does not exist, so pasting a screenshot does nothing. The
biggest single missing feature.

- Content-addressed storage by sha256, so the same screenshot pasted twice is
  stored once.
- **Two separate vision calls**, not one: `Attachment` to describe, `OCRTool`
  to transcribe. The Python app found that asking one prompt to do both
  reliably produces a summary with a few quoted fragments — the model treats
  the text as something to describe rather than something to copy.
- The description is what makes an image routable; the pixels are invisible to
  every similarity comparison.

## 2. To-do lists, properly

Ticking works. Deadlines and check-ins do not.

- `/api/list/settings` — deadline, check-in time, pause, repeat, grouping.
- `/api/list/item/when` — a reminder on a single item.
- **Repeats advancing**: ticking a repeating item should move it to its next
  occurrence rather than finishing it. Parsed today, never acted on.
- `/api/due` only ever returns `task` reminders. `showAlert` can already draw
  `item`, `checkin` and `deadline` cards — that work is done in the page and
  unused.

## 3. The anti-sprawl gate

Two of the six checks exist: exact name match and a collection cap. Missing:
alias memory, `norm_key` collapsing (`Games`/`Gaming`/`My Games`), prefix-aware
near matching, containment meaning nesting rather than merging, and the
two-axis embedding comparison.

Not urgent at twenty notes. It is the difference between a taxonomy and a mess
at two hundred, and it is the hardest single thing in the original.

## 4. Chat, properly streamed

Events are collected and sent in one response, so an answer appears at once
rather than word by word. `HTTPBodySequence` can stream; threading async model
tokens through it is the part worth doing with care.

## 5. The gardener

`/api/garden` returns nothing, so the Tidy up screen is always empty.
k-means over collection centroids to propose merges and dissolves, plus
`/api/garden/apply` and `/api/garden/dismiss`.

Depends on item 0: merge thresholds are the same geometry problem.

## 6. Link tiles, finished

Tiles render. `/api/links/fetch` (thumbnails and previews) and
`/api/links/layout` (drag to arrange) are missing, so tiles have no images and
no custom order.

## 7. Cold-start clustering

At note 20 the Python app runs one k-means pass to derive a starting taxonomy,
naming each cluster from terms its members share. Here collections form one at
a time from the model's proposals instead — workable, but it produces a less
coherent starting shape.

## Deliberately not building

| | Why |
|---|---|
| `/api/connect`, `/api/device/remove` | Pairing. Standalone app. |
| `/api/profile`, `/api/profile/new` | One vault is enough until there are notes worth separating. |
| `/api/ai`, `/api/ai/remove` | Ollama model management. Meaningless here. |
| `/api/personal/*` | The WhatsApp import is prepared by hand on the laptop. |
| `/api/web/test` | Web search. Would send queries off-device; worth a deliberate decision, not a default. |
| Map screen | Low value per unit of effort on a phone. `edges` would need populating first. |
| Share extension, widgets | Need App Groups, which a free Apple ID may not provision. Unverified. |
