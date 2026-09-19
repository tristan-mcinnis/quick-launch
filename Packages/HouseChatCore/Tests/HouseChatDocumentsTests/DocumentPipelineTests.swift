import Foundation
import HouseChatCore
import Testing
@testable import HouseChatDocuments

@Suite("Document text pipeline")
struct DocumentPipelineTests {
    @Test("A character cut keeps whole sections and a head of the crossing one")
    func sectionCut() throws {
        let document = DocumentText(
            sections: (1...3).map { (number: Int) -> DocumentText.Section in
                DocumentText.Section(
                    label: "Page \(number)",
                    unit: .page,
                    index: number,
                    range: DocumentRange(start: number, end: number),
                    body: "0123456789"
                )
            },
            sectionUnit: .page,
            unitCount: 300
        )
        let finished = try document.finished(characterCap: 30)
        #expect(finished.text == "0123456789\n\n0123456789\n\n012345")
        #expect(finished.characterCount == 34)
        #expect(finished.truncation?.summary == "first 30 of 34 characters, pages 1-3 of 300")
        #expect(finished.sections.count == 3)
        #expect(finished.sections.last?.text == "012345")
        #expect(finished.sections.last?.label == "Page 3")
    }

    @Test("A unit cut alone is reported when no characters were dropped")
    func unitCutOnly() throws {
        let document = DocumentText(
            sections: [DocumentText.Section(label: "Page 1", unit: .page, index: 1, body: "words here")],
            sectionUnit: .page,
            unitCount: 5,
            unitCut: DocumentText.UnitCut(unit: .page, kept: 1, total: 5)
        )
        let finished = try document.finished(characterCap: 1_000)
        #expect(finished.truncation == TextTruncation(unit: .page, keptUnits: 1, totalUnits: 5))
        #expect(finished.truncation?.summary == "pages 1 of 5")
    }

    @Test("No readable text throws empty")
    func empty() {
        #expect(throws: DocumentExtractionError.empty) {
            try DocumentText(sections: [.init(body: "  \n")]).finished(characterCap: 100)
        }
    }

    @Test("Extracted sections feed the shared context selector with their locations")
    func contextIntegration() async throws {
        // Three slides of about 1,000 characters each: over the short-document
        // threshold, so the selector splits by section.
        let line = String(repeating: "Slide body text ", count: 90)
        let slides = (1...3).map { Fixtures.Slide(lines: [line], fileNumber: $0) }
        let result = try await DocumentExtractor().extract(
            data: Fixtures.pptx(slides),
            name: "deck.pptx"
        )

        #expect(result.document.sections.count == 3)
        let set = DocumentContext.standard.chunkSet(for: result.document, attachmentID: "a1")
        #expect(set.isWholeDocument == false)
        #expect(set.chunks.map(\.label) == ["Slide 1", "Slide 2", "Slide 3"])
        #expect(set.chunks.allSatisfy { $0.unit == .slide })
        #expect(set.chunks.map(\.sectionIndex) == [0, 1, 2])
        #expect(set.chunks.first?.text.hasPrefix("Slide body text") == true)
    }
}
