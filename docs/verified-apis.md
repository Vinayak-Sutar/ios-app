# API signatures, verified against Apple's docs

Written down because this code is compiled on a CI runner, not here. Every
signature below was read off Apple's reference or the dependency's source, not
recalled — a wrong label costs an eight-minute round trip, and a plausible-looking
guess from a blog post costs two.

## FoundationModels

```swift
// All four of these exist; the ones we use rely on defaulted parameters.
func respond(to:options:)
func respond(to:generating:includeSchemaInPrompt:options:)      // <- the one we call
func respond(to:schema:includeSchemaInPrompt:options:)
func respond(to:generating:options:contextOptions:metadata:)

init(model:tools:instructions:)                                  // all defaulted
var usage: LanguageModelSession.Usage                            // token accounting
var transcript: Transcript
func prewarm(promptPrefix: Prompt?)
```

- **Determinism:** `GenerationOptions(sampling: .greedy)`. Greedy always takes
  the most likely token and *ignores* temperature; there is no seed parameter.
  It is still not stable across OS updates, so routing decisions get logged with
  the OS version.
- **Errors:** `LanguageModelSession.GenerationError` for generation failures
  (guardrail violations live here), and `LanguageModelError.contextSizeExceeded(_:)`
  when the window overflows. Several blog posts name a
  `GenerationError.exceededContextWindowSize` — that is not what the docs say.
- **Availability:** `SystemLanguageModel.default.availability` is
  `.available` or `.unavailable(reason)`, where reason is `.deviceNotEligible`,
  `.appleIntelligenceNotEnabled` or `.modelNotReady`. That enum is the only
  error message the framework gives, so log it verbatim.
- **Structured output:** `@Generable` on structs and enums, `@Guide(description:)`
  on properties. `DynamicGenerationSchema(name:anyOf:)` builds a schema at
  runtime — but developers report values coming back outside the supplied list,
  so it guides rather than constrains. Hence the fixed slot enum in
  `Intelligence.swift` plus an off-menu check in `Router`.

## NaturalLanguage

```swift
init?(script: NLScript)            // also (language:) and (modelIdentifier:)
var dimension: Int                 // READ AT RUNTIME. 512 on iOS, 768 on macOS.
var maximumSequenceLength: Int     // READ AT RUNTIME. Apple publishes no value.
var hasAvailableAssets: Bool
var revision: Int
var modelIdentifier: String

func requestAssets() async throws -> AssetsResult   // .available / .notAvailable / .error
func load() throws
func embeddingResult(for: String, language: NLLanguage?) throws -> NLContextualEmbeddingResult

// The result is SUBWORD-level. Apple's docs say to pool.
func enumerateTokenVectors(in: Range<String.Index>, using: ([Double], Range<String.Index>) -> Bool)
var sequenceLength: Int
```

Note the vectors are `[Double]`, not `[Float]`, and the closure returns `Bool`
to continue.

`NLEmbedding.sentenceEmbedding(for:)` is the simpler alternative, and Apple's
own `NLContextualEmbedding` page points at it for semantic similarity. The
diagnostics page reports both so the MVP can pick on measurement rather than
assumption.

## FlyingFox 0.27.1

```swift
public final actor HTTPServer                        // Sendable, so safe to hand across actors
init(address: some SocketAddress, ...)               // .loopback(port:) — not any-interface
func appendRoute(_ route: HTTPRoute, handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse)
func run() async throws
func stop(timeout: TimeInterval = 0) async
func waitUntilListening() async throws

HTTPRequest.bodyData: Data { get async throws }
HTTPResponse(version:statusCode:headers:body: Data)
HTTPResponse(version:statusCode:headers:body: HTTPBodySequence)   // for the NDJSON chat stream
```

From the README, and it matters: *"iOS will hangup the listening socket when an
app is suspended. Once the app returns to the foreground, `HTTPServer.run()`
detects this, throwing `SocketError.disconnected`. The server must then be
started once more."* `LocalServer` has a supervisor loop for exactly this.

Checked in the source, so `[.contentType: "..."]` is fine and not the
deprecated overload:

```swift
public struct HTTPHeaders: Hashable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (HTTPHeader, String)...)
}
static let contentType = HTTPHeader("Content-Type")
static let ok = HTTPStatusCode(200, phrase: "OK")
static let notFound = HTTPStatusCode(404, phrase: "Not Found")
static let internalServerError = HTTPStatusCode(500, phrase: "Internal Server Error")
```

## Reading CI failures without a token

Workflow logs need an authenticated API call. **Check run annotations do not**,
on a public repo:

```
GET /repos/{owner}/{repo}/commits/{sha}/check-runs
GET /repos/{owner}/{repo}/check-runs/{id}/annotations
```

So the iOS workflow greps its own build log on failure and re-emits each
`error:` line as `::error::`, which turns it into an annotation. That is the
channel compile errors come home through.

## Still unverified

- Whether `LanguageModelSession()` compiles with no arguments at all. Apple's
  own example always passes `instructions:`.
- Everything about how the model actually *behaves*, as opposed to what it
  compiles into.
