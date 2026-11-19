# The `/api/…` surface `app.html` expects

Taken from the page itself, not from memory:

```bash
grep -oE "'/api/[a-zA-Z0-9/_-]*'" mnemo/web/app.html | tr -d "'" | sort -u
```

47 routes. The Swift bridge has to answer the ones the page actually reaches,
and can stub the rest as long as the shape is right — `app.html` has designed
empty states for every section, so an empty list renders as "nothing here yet"
rather than an error.

## Boot order

This is the sequence on load, and it is the order the routes should be built in.
Getting it wrong shows up as a blank screen, which is the least diagnosable
failure available.

| # | Route | Why it matters |
|---|---|---|
| 1 | `GET /api/profiles` | **First call, and it is a liveness probe.** The page requests it with a 6 s (or 2.5 s) timeout and falls back to its offline copy when it times out. Our server is in-process so this always answers, which is what keeps `LIVE` true and `local.js` out of the picture entirely. |
| 2 | `GET /api/state` | The whole shell: collection tree with counts, inbox and review counts, note and collection totals, embedder and router names, cold-start progress. Requested in parallel with `/api/agenda`. |
| 3 | `GET /api/agenda` | Drives the Today screen, the first thing shown. |
| 4 | `GET /api/notes` | The list pane. Takes `topic`, `kind`, `status`. |
| 5 | `GET /api/note?id=` | Note detail. |
| 6 | `GET /api/due` | Polled for reminders. |

## M1: implement

The minimum for the real UI to boot, save a note and read it back.

```
GET  /api/profiles          one profile; there is no profile switching here
GET  /api/state             tree, counts, coldStart, embedder, laptop: true
GET  /api/agenda            notes, items, lists, anytime
GET  /api/notes             ?topic= &kind= &status=
GET  /api/note              ?id=
GET  /api/inbox             notes + review
GET  /api/suggest           ?id=  -> top 3 collections with similarities
POST /api/capture           {text} -> the full capture result
POST /api/note/update       {id, title?, body?}
POST /api/note/new          {title?, body?, topic?, kind?}
POST /api/note/delete       {id}
POST /api/note/discard      {id}       blank notes vanish without a trace
POST /api/move              {id, topic}
POST /api/note/file         {id}       "file it for me"
GET  /api/due               reminders
POST /api/reminded          {keys}     so nothing fires twice
```

## M1: stub

Answer with the right shape and nothing in it. The page renders its empty
states and nothing errors.

```
GET  /api/links        -> {links: []}
GET  /api/personal     -> an empty overview
GET  /api/garden       -> {proposals: []}
GET  /api/graph        -> {nodes: [], edges: []}
GET  /api/lists        -> {lists: []}
GET  /api/ai           -> enough for Settings to render; AI settings are
                          Ollama-specific on the Windows side and mean
                          nothing here
POST /api/undo         -> {undone: null}   until there is a journal
```

## M2

```
POST /api/search            ?q=   substring + vector, fused
POST /api/chat              newline-delimited JSON stream:
                            sources | token | action | step | done | error
POST /api/note/ai           {id, request} -> {action, reply, text, position}
POST /api/note/schedule     {id, when, remind, snooze}
POST /api/note/complete     {id, done}
```

## Later or never

`/api/upload` (images), `/api/list/*` (checklists), `/api/links/*`,
`/api/personal/*`, `/api/garden/apply`, `/api/garden/dismiss`,
`/api/note/append`, `/api/note/order`, `/api/web/test`, `/api/profile`,
`/api/profile/new`.

Three are meaningless in a standalone app and should 404 loudly rather than be
faked: `/api/connect`, `/api/device/remove`, `/api/ai/remove`.

## How to get the shapes right

Do not guess them. Run the Windows app and record the real responses:

```bash
cd D:\temp\mnemo && python -m mnemo serve
```

Then capture each route's JSON into `Tests/NotesCoreTests/Golden/api/` and
compare the bridge's output against it. The contract is the part of the Python
app worth reusing most, and it is already written down — just not in a form a
test can read yet.

## Two details that will bite

- The page sends `X-Notes-Profile` on requests and expects the server not to
  mind. It also reads an `X-Notes-App: 1` response header on the page itself.
- `POST` bodies are JSON, and `/api/chat` is `application/x-ndjson` with
  `Transfer-Encoding: chunked`, one event per line. That streaming requirement
  is the main reason the bridge is a real HTTP server rather than a
  `WKURLSchemeHandler`.

## Recorded shapes

`Tests/NotesCoreTests/Golden/api/*.json` holds real responses captured from
`python -m mnemo serve` against a copy of `samples/demo-vault`, so the bridge
is written against observed JSON rather than a guess. It already paid for
itself: `/api/graph` returns `{links, nodes}`, not the `{nodes, edges}` guessed
above.

`state.json` is the shell contract and the one to match first. The rest were
captured against a freshly indexed vault, so they are empty — which is exactly
what the M1 stubs need, since an empty response is the shape the page's empty
states render from.

Two fields in `state.json` are worth noting. `laptop: true` keeps the page out
of its offline-copy path, which a standalone app always wants. `coldStart: 20`
is the countdown shown in the sidebar while the vault is too new to grow a
taxonomy. Both are ours to fake honestly rather than compute.
