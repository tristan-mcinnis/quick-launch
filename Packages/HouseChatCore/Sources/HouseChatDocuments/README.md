# HouseChatDocuments

The shared, app-agnostic document and image reader for House chat surfaces
(Quick Launch and RTI). It turns local files, raw bytes, and a caller-fetched
web page body into the shared `HouseChatCore` schema (`ExtractedDocument`,
`DocumentSection`, `DocumentNote`, `TextTruncation`) while keeping every cap
and reporting every cut.

- **Floor:** macOS 14, Swift tools 6.0, Swift Testing.
- **Dependencies:** `HouseChatCore` only. No network, no shell, no new
  packages.
- **Not macOS-26-only:** no `Synchronization`/`Mutex`, no SwiftUI. OCR uses
  the macOS 14 Vision API (`VNRecognizeTextRequest`).

## Public API

```swift
public actor DocumentExtractor {
    public static let version: Int
    public nonisolated let configuration: DocumentExtractionConfiguration

    public init(
        configuration: DocumentExtractionConfiguration = .standard,
        recognizeText: @escaping DocumentTextRecognizer = DocumentExtractor.defaultRecognizer
    )

    public func extract(
        fileURL: URL,
        progress: DocumentProgressHandler? = nil
    ) async throws -> DocumentExtraction

    public func extract(
        data: Data,
        name: String,
        sourceURL: URL? = nil,
        bodyWasTruncated: Bool = false,
        progress: DocumentProgressHandler? = nil
    ) async throws -> DocumentExtraction
}
```

`DocumentExtraction` carries everything one read produced:

| Field | Meaning |
| --- | --- |
| `document: ExtractedDocument` | The shared schema record: kind, sections with location, text, truncation, notes, hashes, pixel size. |
| `originalBytes: Data` | The original bytes, byte for byte. Never mutated. Keep-all. |
| `normalizedImage: DocumentImageBytes?` | For a picture only: scaled, metadata-free bytes for transmission. |
| `source: DocumentSource` | `.file` / `.data` / `.fetchedBody`, plus name, file URL, and source URL. |
| `isComplete` | False when a cap stopped the read short. |
| `limitSummary` | The truncation line, or nil. |

`DocumentTextRecognizer` is `@Sendable (CGImage) async -> String`; callers and
tests inject their own. The default is on-device Apple Vision.

## Behaviour

- **Routing** is by extension and content type, then confirmed against the
  bytes. A `.docx` that is not a ZIP says "Not a Word document"; an OLE
  container says "Password-protected".
- **Sections carry location:** label, `DocumentUnit`, 1-based index, and
  `DocumentRange`. PDF pages, PPTX slides, and XLSX sheets each get one
  section, so `HouseChatCore.DocumentContext` chunks them with their
  locations.
- **Limits are reported, never hidden.** A cut sets `TextTruncation` with the
  characters kept and the unit range (`pages 1-2 of 4`), plus the specific
  `DocumentNote` (`ocr`, `spreadsheetSerialDates`, `linkBodyCut`,
  `partialExtraction`). `isComplete` is false for any of these. A scanned PDF
  whose OCR cap skips pages carries a page-range limit line even though no
  characters were cut, so it is never presented as fully read.
- **Malformed HTML keeps its source but not its script.** Block elements
  (`script`, `style`, `nav`, and the rest) are removed when closed, and an
  opener with no close (a body a caller cut mid-script) is discarded to the
  end of the input, so no raw JavaScript reaches the model. `originalBytes`
  still holds the page byte for byte.
- **Cancellation** is checked between pages, slides, entries, and rows.
- **Time is a cooperative deadline, not a hard wall-clock stop.** A read is
  wrapped in a structured 20-second deadline (configurable). At the deadline
  the work is cancelled and then joined: cancellation-aware units stop
  promptly, and a blocking native unit with no cancel hook runs to the end of
  its current section before the call returns. Nothing is left running in the
  background. On-device OCR is cancelled through `VNRequest.cancel()`.

### Caps (defaults)

| Cap | Default |
| --- | --- |
| Document file | 50 MB |
| Text/Markdown/code/HTML file | 5 MB |
| Image file | 20 MB |
| Extracted text per file | 2,000,000 characters |
| PDF pages | 300 |
| OCR pages | 10 |
| Slides | 300 |
| Sheets | 10 |
| Rows per sheet | 5,000 |
| Columns per sheet | 100 |
| ZIP entries / entry output / archive output | 5,000 / 16 MB / 64 MB |
| ZIP declared ratio | 200 (with a 1 MB floor) |
| Image long side | 2,048 px |
| Image PNG ceiling before JPEG fallback | 2 MB |
| Time | 20 s cooperative deadline |

Text is capped at 2 million characters for retention. Request-time model
budgets (the 200,000/400,000 ceilings and chunk selection) are applied later
by `HouseChatCore.DocumentContext`, not here.

### Images: original vs normalized

- `originalBytes` is the file exactly as it arrived, EXIF and GPS included.
  The module never rewrites it.
- `normalizedImage` is decoded, scaled to the long-side cap, re-encoded as PNG
  (or JPEG when the PNG passes the ceiling), and therefore carries no source
  metadata. This is the copy a model may receive.

### Links

Link fetching stays in the app adapter. The adapter fetches the body, then
calls `extract(data:name:sourceURL:bodyWasTruncated:)`. When `sourceURL` is
http/https, the source kind is `.fetchedBody`, a fetched HTML page is recorded
as `.link` ("Web page"), and `originalBytes` is the body. Pass
`bodyWasTruncated: true` when the adapter cut the body at its own download cap;
the record then carries a `linkBodyCut` note. A body cut mid-`<script>` has the
script discarded rather than leaked into the model text.

### Rich text

A `.rtfd` folder is read as a package. A flat regular file named `.rtfd` is
the flat RTFD form, which is RTF, so it is decoded with the RTF document type;
junk in a flat `.rtfd` is still refused. A package's bytes are capped on the
bytes actually read, so a file that grows between the metadata check and the
read cannot be returned over the cap.

The only non-HTTP file operation that can touch the network is macOS iCloud
coordination inside the gate (`startDownloadingUbiquitousItem`), preserved from
the Quick Launch gate. It is a coordinated file read, not a web fetch.

## Relationship to the Quick Launch extractors

This module adapts the tested Quick Launch implementations:
`AttachmentExtractor`/`AttachmentFileGate` → `DocumentExtractor`/
`DocumentFileGate`; `PlainTextReader`, `PDFTextExtractor`,
`OOXMLTextExtractor`, `OOXMLArchive`, `HTMLTextExtractor`,
`AttributedDocumentReader`, and `AttachmentImageReader` are carried over with
the shared schema names and a public result type. The OCR entry point uses the
macOS 14 Vision API rather than the app's macOS 26 `RecognizeTextRequest`.

## Tests

Tests in `Tests/HouseChatDocumentsTests/`. Fixtures are built in code (no
committed binaries): docx, pptx, xlsx, ZIP bombs, text/locked/scanned/mixed
PDFs, and PNG/JPEG-with-EXIF images. They cover Office, PDF, plain text, code,
HTML, images, corrupt and wrong-type input, ZIP bombs, a scanned-empty PDF,
truncation, tail content, the OCR cap on pure and mixed scans, unclosed and
cut HTML blocks, flat `.rtfd`, the package read cap, the cooperative deadline,
and one real on-device OCR pass.

To run them before the target is added to `HouseChatCore/Package.swift`, point
a temporary package at this directory and the core sources; the harness used
during development added:

```swift
.target(name: "HouseChatDocuments", dependencies: ["HouseChatCore"],
        path: "Sources/HouseChatDocuments"),
.testTarget(name: "HouseChatDocumentsTests",
            dependencies: ["HouseChatDocuments", "HouseChatCore"],
            path: "Tests/HouseChatDocumentsTests")
```

## Not supported here

- `.doc`-era and `.ppt`/`.xls` binary formats, Keynote/Pages/Numbers
  packages, and archives: refused with a way out.
- Fetching links, password prompts, and model-budget selection: the caller's
  job.
