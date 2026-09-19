# HouseChatCore

The shared chat core for **Quick Launch** and **RTI**. One schema for chat
history, two owner-only archives, the retrieval policy, slash commands, and
deterministic document selection. Foundation only: no UI, no network, no model
call.

This README is the API handoff, written to be read once by a consuming worker.

```
path:  quick-launch/Packages/HouseChatCore
floor: macOS 14   tools: swift-tools-version 6.0   swift: 6 language mode
test:  cd Packages/HouseChatCore && swift test      # use the current run's count
```

## Two products, one package

| product | target | what it owns |
| --- | --- | --- |
| `HouseChatCore` | `Sources/HouseChatCore` | schema, archives, commit transaction, retrieval policy, commands, chunk selection |
| `HouseChatDocuments` | `Sources/HouseChatDocuments` | reading PDF/DOCX/PPTX/XLSX/HTML/text/images into `ExtractedDocument` |

`HouseChatDocuments` depends on `HouseChatCore`; the dependency never runs the
other way, and `HouseChatCore` does not import it. Extraction is consumed through
the shared `ExtractedDocument` schema, so a consumer can record a document it
extracted today and read it back after extraction changes. Its own API and caps
are documented in `Sources/HouseChatDocuments/README.md`.

Consumer import:

```swift
import HouseChatCore        // schema, archives, policy, selection
import HouseChatDocuments   // DocumentExtractor, when the app reads files
```

## File map (HouseChatCore)

```
Coding/JSONValue.swift          any-JSON value, for unknown keys
Coding/ExtraFields.swift        unknown-key preservation, AnyCodingKey, required-string decode
Coding/HouseChatCoding.swift    schema version, JSON encoder/decoder, ISO 8601 dates
Schema/AppPayload.swift         EndpointDescriptor, SecretRedactor, AppPayload
Schema/ArtifactRef.swift        ArtifactRef (kind + kindRaw + sha256 + byteCount)
Schema/AttachmentRecord.swift   AttachmentRecord, AttachmentArtifacts, AttachmentSnapshotRef
Schema/ConversationRecord.swift ConversationRecord
Schema/TurnRecord.swift         TurnRecord
Schema/RequestReceipt.swift     RequestReceipt, RequestStatus, sanitizedForStorage()
Schema/ChatValueTypes.swift     ModelChoice/ModelSelection, SessionLink, timings, usage,
                                ToolCall/ToolRound/ToolRoundStatus, RetrievalScope, ContextReceipt
Schema/DocumentSchema.swift     DocumentUnit, DocumentSection, DocumentRange, DocumentNote,
                                TextTruncation, DocumentUnitCut, ExtractedDocument
Storage/SHA256Digest.swift      lowercase-hex SHA-256 helpers
Storage/AtomicFile.swift        O_NOFOLLOW + 0600-at-creation atomic writes, atomic mkdir, lstat
Storage/ArchiveRootLock.swift   flock(2) exclusive lock over one archive root
Storage/AttachmentArchive.swift actor: immutable, content-addressed byte store
Storage/ConversationArchive.swift actor: one JSON file per conversation
Storage/ChatCommitCoordinator.swift actor: atomic attachment+turn commit, fail-closed reference scans
Context/ContextPolicy.swift     QuestionIntent, ContextOverride, ContextRequest, ContextDecision
Context/DocumentContext.swift   chunking + lexical selection
Commands/ChatCommand.swift      /new, /clear, app commands, unknown-command error
```

## 1. Schema

Every stored record is `Codable & Sendable`; every field older writers may lack
is optional; unknown keys survive a round trip.

```swift
import HouseChatCore

let attachment = AttachmentRecord(
    id: "a1",
    kind: .pdf,
    name: "report.pdf",
    byteCount: 512_000,
    pageCount: 12,
    characterCount: 84_000,
    contentHash: SHA256Digest.hex(originalBytes),   // the original, unredacted
    extractorVersion: 1,
    path: "/Users/me/report.pdf",                   // only when a real file exists
    artifacts: AttachmentArtifacts(original: originalRef, extractedText: textRef)
)

let userTurn = TurnRecord(role: .user, text: "Summarize this", attachments: [attachment])
let conversation = ConversationRecord(
    id: "chat-1",
    surface: .quickLaunch,
    title: "Report",
    turns: [userTurn],
    appVersion: "1.4.0"
)
```

**Records:** `ConversationRecord`, `TurnRecord`, `AttachmentRecord`,
`RequestReceipt`, `ToolRound`, `ConversationEnvelope`, `ConversationBundle`,
`ConversationSummary`, `ExtractedDocument`.

**Per-turn model/provider/thinking:** `TurnRecord.model` is the concise
`ModelSelection` (`chosen` vs `effective`, each a `ModelChoice` of
`provider`/`model`/`thinking`). `TurnRecord.request` is the full
`RequestReceipt`: selection, `status`, `context` (`ContextReceipt`), `endpoint`
(see below), `attachmentRefs` (content hash + snapshot hash), `toolRounds`,
`timings`, `usage`, and `error`.

**Identity and content are required.** A stored record missing a conversation
`id` or `turns`, a turn `id`/`role`/`text`/`attachments`/`toolRounds`/
`sessionLinks`, a request receipt's `attachmentRefs`/`toolRounds`, an
attachment `id`/`kind`/`name`, or an extracted document's `kind`/`name` fails to
decode, and an empty string is not an identity. An explicit `null` where one of
those belongs fails too: null and absence are both damage, never 0 turns. An
empty array is a legitimate empty list. A damaged record is an error, never a
record with an invented UUID or empty text. Only metadata is optional, which is
what a legacy adapter supplies.

**Stored content and metadata preserve unknown keys.** Each of these carries
`extra: ExtraFields`, captured on decode and written back at the same level on
encode:

`ConversationRecord`, `TurnRecord`, `AttachmentRecord`, `AttachmentArtifacts`,
`AttachmentSnapshotRef`, `RequestReceipt`, `ToolRound`, `ToolCall`,
`ModelChoice`, `ModelSelection`, `SessionLink`, `TurnTimings`, `RequestTimings`, `TokenUsage`,
`ContextReceipt`, `DocumentSection`, `DocumentRange`, `DocumentNote`, `DocumentUnitCut`,
`TextTruncation`, `ExtractedDocument`, `ArtifactRef`, `ConversationEnvelope`,
`AppPayload`.

```swift
let record = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)
record.turns[0].request?.usage?.extra["futureUsage"]   // JSONValue? — preserved verbatim
```

A preserved number that is integral but too large for a `Double` (above 2^53,
for example a nanosecond timestamp or a large id) keeps its exact value and
re-encodes as the same literal.

Derived listing/export wrappers (`ConversationSummary`, `ConversationBundle`)
use their declared fields only. `AppPayload` preserves both its outer unknown
keys and its app-specific `values`; an absent `values` object means an empty
bucket, not a corrupt conversation.

`EndpointDescriptor` is a deliberate security exception: it rebuilds only its
whitelisted destination fields through the sanitizer. Unknown endpoint keys
are not retained as opaque data that might bypass credential filtering.

**Enums tolerate the future.** An unknown `role`, `kind`, `status`, or unit
decodes to `.unknown`/`.other` while keeping the original string
(`AttachmentRecord.kindRaw`, `ArtifactRef.kindRaw`). An unknown
`ArtifactRef.Kind` is never treated as `.original`: see §2. An unknown
`RetrievalScope` is never treated as `.none`: the receipt's `scope` is left
unstated and `ContextReceipt.scopeRaw` holds the original string.

**Dates** are ISO 8601 with fractional seconds. Always use
`HouseChatCoding.makeEncoder(prettyPrinted:)` / `makeDecoder()`.

**Per-app fields.** `ConversationRecord.appPayload` and `TurnRecord.appPayload`
hold an `AppPayload` (namespace + `ExtraFields`) for fields only one app models:
QL's `titleSource`, `assistantID`, `enabledTools`, `cards`, `toolRecords`; RTI's
equivalents. They stay namespaced so the shared schema never grows a second
owner.

**Images are not redacted.** Keep-all: an `AttachmentRecord` stores every fact it
is given, including an image's `contentHash`, `extractorVersion`, `path` (only
when a real file path exists), and pixel size. Nothing is fabricated and nothing
is silently dropped.

### Credentials: what is and is not guaranteed

There is **no blanket guarantee that no credential can be serialized.** The
honest statement:

- **The typed endpoint is safe by construction.** `RequestReceipt.endpoint` is an
  `EndpointDescriptor`, and every way to build or decode one removes userinfo,
  cuts the query string (where `?api_key=` lives) and the fragment, redacts a
  credential-shaped path segment, and lowercases the host. A stored or
  hand-written endpoint is re-sanitized on decode, so it cannot smuggle a query
  back in.
- **Free text is the consumer's to scrub.** `TurnRecord.text`,
  `RequestReceipt.error`, tool `arguments`/`resultSummary`, `extra`, and
  `AppPayload` are stored exactly as given. A provider error that echoes the URL
  it called will be written verbatim. Use `SecretRedactor` and
  `RequestReceipt.sanitizedForStorage()` before writing:

```swift
let receipt = rawReceipt.sanitizedForStorage()   // redacts error + tool call text
let line = SecretRedactor.redact(providerError)  // URLs, key=value and "key": "value" pairs, Bearer, sk-… prefixes
```

```swift
EndpointDescriptor(url: URL(string: "https://u:secret@api.example.com/v1/chat?api_key=sk-1")!)
//  .sanitized == "https://api.example.com/v1/chat"

let rejected = EndpointDescriptor(validatingScheme: "https", host: "  ")  // nil
let empty = EndpointDescriptor(scheme: "https", host: "  ")              // isUsable == false, sanitized == ""
```

## 2. AttachmentArchive — the bytes

```swift
let archive = try AttachmentArchive(root: containerURL)   // root injected, never hardcoded

let ref = try await archive.store(originalData, kind: .original, fileExtension: "pdf")
_ = try await archive.store(normalizedPNG, kind: .normalizedImage, fileExtension: "png")
_ = try await archive.store(extractedText, kind: .extractedText, fileExtension: "txt")
_ = try await archive.store(requestJSON, kind: .requestSnapshot, fileExtension: "json")

let bytes = try await archive.read(ref)                    // verifies hash and size
try await archive.verify(ref)                              // .verified / .missing / .mismatched
let all = try await archive.list(kind: .original)
let removed = try await archive.removeUnreferenced(keepingHashes: referenced)
```

`ArtifactRef.Kind.storable`: `.original`, `.normalizedImage`, `.extractedText`,
`.requestSnapshot`. The fifth case, `.unknown`, has no directory and no
operations: `store`, `read`, `remove`, `verify`, and `contains` all refuse it
(`unsupportedKind`, `.missing`, `false`) instead of treating it as `.original`.
`list()` enumerates only storable kinds, so an unknown-kind record can never be
swept into a removal.

Semantics, all tested:

- **Content addressed.** `<root>/<kind>/<first two hex>/<sha256>`; the extension
  is metadata for exporters, never part of the path. Storing the same bytes twice
  returns the same ref and writes one file.
- **Owner only.** Directories are created 0700 and files 0600 in the syscall that
  creates them; writes go through a 0600 temp file, an atomic rename, and a
  directory fsync. An archive directory that already exists is **narrowed** to
  0700 when the process owns it; a directory it does not own is left alone, and
  no ancestor is ever touched.
- **Concurrent-safe directory creation.** `lstat`, then an atomic `mkdir`, then a
  second `lstat` only on `EEXIST`. A directory another process created in
  between is accepted, not mistaken for an unsafe path.
- **Hash and size verified on read.** `read` hashes the bytes again and rejects a
  mismatch or a wrong size as `.corrupt`; absent is `.missing`. Tampered bytes
  are never returned as the artifact.
- **No eviction.** No cap, no expiry, no timer. The only bulk removal is
  `removeUnreferenced(keepingHashes:)`. `remove` deletes one named artifact.
- **Path safety.** A digest must be 64 lowercase hex before it is joined to a
  path. The root, the kind directory, and the prefix directory must all be real
  directories: a symlink at any of them is refused with `.unsafePath` on writes,
  reads, and deletes; the file is opened `O_NOFOLLOW`.
- **Originals are immutable and never redacted.** Store the user's bytes whole,
  even when extraction read only part of them.

## 3. ConversationArchive — the histories

```swift
let conversations = try ConversationArchive(root: containerURL)
let summary = try await conversations.save(conversation)        // atomic, 0600
let loaded  = try await conversations.load(id: "chat-1")        // .missing vs .corrupt
let envelope = try await conversations.envelope(forID: "chat-1")
let listed  = try await conversations.list()                    // newest first
try await conversations.delete(id: "chat-1")
let one     = try await conversations.export(id: "chat-1")
let bundle  = try await conversations.exportAll()
let wrote   = try await conversations.saveIfAbsent(conversation) // idempotent
```

- One JSON file per conversation: `"<slug>-<hash of ID>.json"` under the root.
  Any ID is safe; the hash suffix makes the mapping exact.
- `ConversationEnvelope` carries `format` (`"house-chat-conversation"`),
  `schemaVersion`, `savedAt`, and the `ConversationRecord`.
- Integrity checks on read: a readable regular file, the expected format, a
  supported schema at **both** the envelope and the conversation level, and a
  conversation whose own `id` equals the one asked for. Garbage → `.corrupt`,
  absent → `.missing`, newer → `.unsupportedSchema`.
- `list` returns a `ConversationSummary` per file and marks a damaged file with
  `issue` (`.corrupt`, `.unsupportedSchema`, `.unreadable`) instead of hiding it.
  An empty archive lists `[]`; a root that exists but cannot be listed **throws**
  `.rootUnreadable`.
- The root must be a real directory; a symlinked root is refused (`.unsafeRoot`).
- `saveIfAbsent` validates the ID first, so an unusable ID throws
  `.invalidID` rather than reporting "nothing to do".
- `save` refuses a conversation whose own `schemaVersion` is newer than this
  build's (`.unsupportedSchema`), so it can never write a file its own
  `load`/`list` would reject.
- `exportAll` throws when a file `list()` vouched for then fails to load: a
  whole-app export is never silently short a chat.

**Legacy migration (idempotent, consumer-owned).** The package does not know
QL's or RTI's old formats. A consumer adapter reads its own legacy file, builds a
`ConversationRecord`, and calls `saveIfAbsent(_:)`. Run it twice and the second
run is a no-op. Add `AppPayload` for the app-only fields.

## 4. ChatCommitCoordinator — one atomic commit

```swift
let coordinator = ChatCommitCoordinator(attachments: archive, conversations: conversations)
// Default: an ArchiveRootLock over the attachments root, so commits and
// deletions serialize across coordinators and processes.

let commit = try await coordinator.commit(
    conversation: conversation,          // the turn is already appended
    turnIndex: 0,
    artifacts: [
        PendingArtifact(role: .original,        data: originalBytes, fileExtension: "pdf", attachmentIndex: 0),
        PendingArtifact(role: .normalizedImage, data: png,           fileExtension: "png", attachmentIndex: 0),
        PendingArtifact(role: .extractedText,   data: textData,      fileExtension: "txt", attachmentIndex: 0),
    ]
)
// commit.conversation carries the attached refs; commit.createdDigests lists what this commit wrote
```

- Artifacts are written first, the conversation second; the caller builds the
  conversation and decides when to commit. **Every blob goes through the
  commit** — originals, normalized images, extracted text, and request
  snapshots. A direct `AttachmentArchive.store` in a send path would run outside
  the root lock and could be deleted by a concurrent scan, so the seam is one
  call:

```swift
// The receipt needs the hash before the commit, so build the snapshot ref from
// the same bytes that will be submitted.
let snapshot = AttachmentSnapshotRef(snapshotData: requestJSON, kind: "requestSnapshot")
let receipt = RequestReceipt(status: .completed, attachmentRefs: [snapshot])

try await coordinator.commit(
    conversation: conversation,
    turnIndex: 0,
    artifacts: [
        PendingArtifact(role: .original, data: originalBytes, fileExtension: "pdf", attachmentIndex: 0),
        PendingArtifact(role: .requestSnapshot, data: requestJSON, fileExtension: "json"),
        // no attachmentIndex: a snapshot belongs to the turn, not to one file
    ]
)
// The stored artifact's sha256 equals snapshot.snapshotHash by construction.
```

  A `requestSnapshot` with a non-nil `attachmentIndex` is refused with
  `ChatCommitError.requestSnapshotCannotAttach` before anything is written: the
  schema has no snapshot slot on `AttachmentArtifacts`, so it is never filed
  under a role it does not own.
- **A failed commit never deletes anything.** The bytes it wrote are retained
  and reported:

```swift
catch ChatCommitError.commitFailed(let conversationID, let turnIndex, let detail, let retainedOrphans) {
    // retainedOrphans are still on disk. Keep them, or clean them up later:
    let removed = try await coordinator.removeArtifactsIfUnreferenced(retainedOrphans)
}
```

  This is deliberate. Content addressing means two commits can hold a ref to the
  same bytes, and a scan cannot see a commit that has not saved yet. A rollback
  that deleted a blob another commit already holds would lose that chat's data.
  Keeping the orphan is the safe direction, and "keep all" is the contract: an
  unreferenced blob costs disk, a missing one costs data.
- **One root lock.** `commit` and `removeArtifactsIfUnreferenced` both run under
  `ArchiveRootLock` (default: the attachments root). Two coordinators, two chats,
  or two processes cannot interleave a store with a delete, so a deletion scan
  always sees every finished commit: a commit either saved its conversation
  (visible) or failed (its bytes retained). A waiter polls with a small backoff
  (`LOCK_NB` plus sleep), so the lock never blocks a thread and never wedges a
  concurrency pool.
- **Deletion is still fail-closed on unknown state.**

```swift
let referenced = try await coordinator.referencedDigests()      // throws when a scan is incomplete
let owners     = try await coordinator.owners(of: digest)        // ["chat-1", "chat-3"]
let removed    = try await coordinator.removeArtifactsIfUnreferenced([ref])
```

- `referencedDigests`, `owners`, and `removeArtifactsIfUnreferenced` all throw
  `referenceScanIncomplete` rather than returning a set that is missing an
  unreadable owner's references.

**What the lock does and does not cover.** It serializes everything that goes
through a coordinator over that root, including across processes: `flock(2)` on
`<root>/.house-chat.lock` (0600, `O_NOFOLLOW`), released when the descriptor
closes, so a crash cannot leave it held. It is advisory. A caller that writes or
deletes through `AttachmentArchive` directly, bypassing the coordinator, is
outside the lock and outside the guarantee.

## 5. ContextPolicy — what a request may retrieve

```swift
let decision = ContextPolicy.standard.resolve(ContextRequest(
    hasCurrentSource: true,
    currentSourceCount: 1,
    historyTurnCount: 4,
    historyHasSources: true,
    question: "Compare this with the earlier file"
))

decision.execution               // .currentSource / .currentSourceAndHistory / .history / .none
decision.sourceFirst
decision.includesHistory
decision.offered                 // scopes the consumer MAY offer
decision.allowsExternalRetrieval // web search, fetch, vault, the app's other tools
decision.intent                  // asksAbout{History,Comparison,BroadSummary,ExternalSearch}
decision.rationale
```

**Inside the conversation** (`execution`):

| situation | execution |
| --- | --- |
| no current source, history exists | `.history` |
| current source, neutral question | `.currentSource` (history only *offered*) |
| current source, question asks for history or a comparison | `.currentSourceAndHistory` |
| current source, broad summary question | `.currentSourceAndHistory` |
| nothing anywhere | `.none` |
| `override: .sourceOnly` | `.currentSource` (or `.none`), never history |

**Outside it** (`allowsExternalRetrieval`):

| situation | external |
| --- | --- |
| ordinary chat: no current source and history carried no sources | **allowed** |
| current source present, or history carried sources (follow-ups included) | withheld |
| a named outside target ("the web", "online", "the vault", "other projects", "上网", "知识库") | allowed |
| a bare cue ("search", "latest", "news", "搜一下") while a source is present | withheld |
| a broad summary, a comparison of attached documents, a mention of earlier turns | withheld |
| `override: .broader` or `.history` | allowed, whatever earlier turns held |
| `override: .sourceOnly` | refused, even with external wording |

So `search for revenue`, `latest revenue figure`, `搜一下收入`,
`search this file for revenue`, `What is the latest figure in this report?`, and
`search the earlier discussion` all stay inside the conversation, while
`search the web for revenue` and `check the vault for the old numbers` do not.

**Consumers enforce both.** The policy returns; it does not execute. Run
retrieval only inside `execution`, offer `offered` and re-resolve with an
override when accepted, and gate every tool that reaches outside the
conversation on `allowsExternalRetrieval`.

Matching is lexical and deterministic: lowercased words for English, substring
for CJK, configurable term sets via `ContextPolicy.Configuration`, no model, no
network, no clock.

## 6. ChatCommand

```swift
let parser = ChatCommandParser(
    knownCommands: ["/meeting", "/notes", "/export"],   // RTI keeps its commands
    aliases: ["/reset": "/clear", "/mtg": "/meeting"]
)

switch parser.parse(input) {
case .command(let command):
    switch command.name {
    case .new:   startNewChat()
    case .clear: clearTurns()
    case .known(let name): appCommand(name, command.arguments)
    }
case .notACommand: sendToModel(input)
case .unknown(let rawName, let message): showLocalError(message)   // never prompt text
case .empty: break
}
```

`/new` and `/clear` are always recognized, matched case-insensitively, and never
shadowed by an alias. Plain text is `.notACommand`; whitespace is `.empty`.

## 7. DocumentContext — selection (no extraction, no network)

```swift
let context = DocumentContext.standard
let set = context.chunkSet(for: extractedDocument, attachmentID: "a1")

let selection = context.select(query: question, in: set)
selection.matched        // false when nothing matched
selection.reason         // .wholeDocument / .rankedMatches / .distributedCoverage
                         // / .noMatch / .budgetExhausted / .emptyDocument
selection.chunks         // [DocumentChunk]: text + label ("Page 3 · part 2 of 5") + offsets
selection.labels         // coverage labels for a receipt
selection.characterCount // exactly selection.text.count, separators included
selection.note           // "No passage in report.pdf matched the question."

// All attachments under one request budget, in the caller's order:
let plan = context.select(query: question,
                          documents: [AttachmentDocument(attachmentID: "a1", document: doc)],
                          budget: 400_000,
                          intent: ContextPolicy.standard.classify(question))
plan.selections["a1"]        // per attachment
plan.contributing            // the selections that carry text
plan.text                    // exactly what would be sent
plan.totalCharacters         // == plan.text.count, separators included
plan.truncatedByBudget
```

Rules:

- a document of at most `shortDocumentCharacters` (2,000) is kept **whole** and
  marked complete. `matched` is true because content is provided, not because
  the query matched; `reason == .wholeDocument` and `isComplete` say which;
- a longer one is split at `chunkCharacters` (2,000) with `overlapCharacters`
  (200) of overlap, so a fact on a boundary lands in a chunk;
- ranking picks at most `maximumChunksPerAttachment` (12) chunks: distinct query
  tokens first, occurrences second, chunk order last;
- broad questions spread labelled coverage evenly across the document;
- **zero match is honest**: `matched == false`, no chunks, `reason == .noMatch`,
  a `note`;
- the budget counts everything that is sent: chunk text plus the two-character
  separator between chunks and between attachments. An attachment that
  contributes nothing needs no separator. `plan.totalCharacters ==
  plan.text.count`, and neither exceeds the budget;
- `labels` are receipt metadata and are never part of the counted text.

`DocumentContext.tokens(of:)` is public: lowercased words of two or more
characters plus every CJK bigram.

## 8. Guarantees and their tests

| guarantee | test |
| --- | --- |
| 0700 dirs / 0600 files, atomic writes, no temp residue, existing roots narrowed | `AttachmentArchiveTests.storesEveryKind`, `ConversationArchiveTests.noTempFiles`, `VerifierRegressionTests.existingRootIsTightened` |
| concurrent stores from several archives never report an unsafe path | `VerifierRegressionTests.concurrentDirectoryCreation` |
| content addressing, idempotent store | `AttachmentArchiveTests.idempotentStore` |
| read verifies hash and size; corrupt ≠ missing | `AttachmentArchiveTests.readDistinguishesCorruptFromMissing` |
| no eviction; only explicit removal | `AttachmentArchiveTests.noEviction` |
| forged digest cannot escape the root | `AttachmentArchiveTests.forgedDigest` |
| symlink refused at the file, the prefix dir, and the root | `refusesSymlink`, `refusesSymlinkedPrefixDirectory`, `refusesSymlinkedRoot`, `RootIntegrityTests.symlinkedRoot` |
| root `/` refused; traversal IDs stay inside | `RootIntegrityTests` |
| missing vs corrupt vs newer-schema vs wrong-ID conversation; unreadable root throws | `ConversationArchiveTests` |
| identity and content required, empty identity fails closed | `SchemaCodingTests`, `VerifierRegressionTests.emptyIdentityFailsClosed` |
| content-bearing arrays required; explicit null fails, `[]` is legal | `SchemaCodingTests.contentArraysAreRequired` |
| an extracted document needs its `kind` and `name` | `SchemaCodingTests.extractedDocumentNeedsIdentity` |
| an integral unknown number above 2^53 round trips verbatim | `VerifierRegressionTests.integralUnknownNumberStaysExact` |
| a quoted credential pair (`"api_key": "…"`) is redacted | `VerifierRegressionTests.quotedCredentialPairsAreRedacted` |
| unknown content/metadata keys preserved, endpoint security exception explicit | `VerifierRegressionTests.nestedUnknownKeysSurvive`, `SchemaCompatibilityRegressionTests` |
| unknown artifact kinds preserved and refused by every operation | `VerifierRegressionTests.unknownArtifactKindRefused` |
| GC fails closed on a corrupt or newer-schema owner | `gcFailsClosedOnCorruptOwner`, `gcFailsClosedOnUnsupportedSchema` |
| a failed commit retains its bytes, even on an incomplete scan | `ChatCommitCoordinatorTests.failedCommitRetainsCreatedBytes`, `VerifierRegressionTests.rollbackFailsClosedOnIncompleteScan` |
| endpoint sanitized in every constructor and on decode; empty when unusable | `memberwiseEndpointSanitized`, `decodedEndpointResanitized` |
| free text scrubbing available before storage | `secretRedactor` |
| a failed commit cannot delete bytes another commit already holds | `StorageSafetyTests.sameBytesTwoCommitsCannotLoseTheBlob` |
| commits and deletions serialize on one root lock, across coordinators | `StorageSafetyTests.rootLockSerializes`, `gcDoesNotRaceCommits` |
| a symlink where the lock file belongs is refused | `StorageSafetyTests.lockRefusesSymlink` |
| a request snapshot travels through the commit, matches the receipt hash, and is kept by GC | `StorageSafetyTests.requestSnapshotTravelsWithTheCommit` |
| a snapshot orphan survives a failed save | `StorageSafetyTests.requestSnapshotRetainedOnFailure` |
| a snapshot with an attachment index is refused before any write | `StorageSafetyTests.snapshotIndexRefused` |
| a pristine nested root works on the first commit, lock included | `StorageSafetyTests.pristineNestedRoot` |
| deletion reference checks across chats | `ChatCommitCoordinatorTests.deletionReferenceChecks` |
| source-first, explicit widening, external gating (EN+CJK), target-only widening | `ContextPolicyTests`, `VerifierRegressionTests.bareCueSuppressedBySourceMention`, `explicitExternalStillWidens` |
| builtins, aliases, unknown command | `ChatCommandTests` |
| whole short docs, tail facts, overlap, budget incl. separators, zero-match honesty, CJK | `DocumentContextTests`, `planBudgetCountsSeparators`, `selectionCountsSeparators` |

## Consumer notes

1. Inject a root you own (`applicationSupportDirectory/…`); nothing is
   hardcoded. Create it once per app.
2. Use `HouseChatCoding` for every encode/decode so both apps write one format.
3. **The boilerplate is yours.** Building `AttachmentRecord`s, `PendingArtifact`s,
   `AttachmentSnapshotRef`s (`AttachmentSnapshotRef(snapshotData:)` gives you
   the hash for the same bytes you then submit), and `RequestReceipt`s is
   consumer code. The package stores what you build; it
   does not assemble snapshots for you.
4. Persist through `ChatCommitCoordinator.commit` when a turn carries bytes, and
   delete bytes only through `removeArtifactsIfUnreferenced`. One coordinator (or
   one `ArchiveRootLock`) per root: the lock is advisory, so a writer that
   bypasses it is outside the safety guarantee.
5. A failed commit leaves its bytes on disk on purpose. Keep the `retainedOrphans`
   from `ChatCommitError.commitFailed` and clean them up later, or never: an
   unreferenced blob is cheap, a lost one is not.
6. Scrub free text with `SecretRedactor` / `sanitizedForStorage()` before writing
   a receipt if a provider error or a tool argument could echo a URL or a key.
7. Run retrieval only inside `decision.execution`; gate outbound tools on
   `decision.allowsExternalRetrieval`.
8. Keep the legacy format adapter in the app; the package guarantees only an
   idempotent `saveIfAbsent`.
9. Read documents with `HouseChatDocuments` and store what it returns through
   `ExtractedDocument`; that keeps extraction swappable.

## Not here

- Reading documents: that is `HouseChatDocuments` (`Sources/HouseChatDocuments`,
  its own README), consumed through `ExtractedDocument`.
- Model/provider clients, tools, prompts, UI, and app-specific defaults.
- Migration of QL's or RTI's on-disk legacy format: the adapter is the
  consumer's, calling `saveIfAbsent`.
