import Foundation
import Testing
@testable import HouseChatCore

@Suite("Nested schema compatibility")
struct SchemaCompatibilityRegressionTests {
    private func roundTrip<T: Codable>(_ type: T.Type, _ json: String) throws -> [String: Any] {
        let value = try HouseChatCoding.makeDecoder().decode(type, from: Data(json.utf8))
        let data = try HouseChatCoding.makeEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func selectionAndRangePreserveUnknownFields() throws {
        let selection = try roundTrip(ModelSelection.self, #"{"chosen":{"model":"fixture"},"futureSelection":{"enabled":true}}"#)
        let future = try #require(selection["futureSelection"] as? [String: Bool])
        #expect(future["enabled"] == true)
        let range = try roundTrip(DocumentRange.self, #"{"start":2,"end":4,"futureLocation":"appendix"}"#)
        #expect(range["futureLocation"] as? String == "appendix")
    }

    @Test func payloadEnvelopeAndValuesBothSurvive() throws {
        let payload = try roundTrip(AppPayload.self, #"{"namespace":"ql","values":{"appFlag":true},"futurePayload":17}"#)
        #expect(payload["namespace"] as? String == "ql")
        #expect(payload["futurePayload"] as? Int == 17)
        #expect((payload["values"] as? [String: Bool])?["appFlag"] == true)
    }

    @Test func missingPayloadValuesDoesNotInvalidateConversation() throws {
        let data = Data(#"{"id":"fixture-thread","appPayload":{"namespace":"ql","futurePayload":"kept"}}"#.utf8)
        let record = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)
        #expect(record.appPayload?.namespace == "ql")
        #expect(record.appPayload?.values.isEmpty == true)
        #expect(record.appPayload?.extra["futurePayload"] == .string("kept"))
    }

    @Test func payloadMergeKeepsBothEnvelopeExtras() {
        let first = AppPayload(namespace: "ql", extra: ExtraFields(["first": .bool(true)]))
        let second = AppPayload(namespace: "ql", extra: ExtraFields(["second": .bool(true)]))
        let merged = first.merging(second)
        #expect(merged.extra["first"] == .bool(true))
        #expect(merged.extra["second"] == .bool(true))
        #expect(!merged.isEmpty)
    }

    @Test func partialCoverageNamesActualUnitsAndRoundTrips() throws {
        let cut = TextTruncation(unit: .page, keptUnits: 3, totalUnits: 4, coveredUnits: [1, 2, 4])
        #expect(cut.summary == "pages 1, 2, 4 of 4")
        let data = try HouseChatCoding.makeEncoder().encode(cut)
        let decoded = try HouseChatCoding.makeDecoder().decode(TextTruncation.self, from: data)
        #expect(decoded == cut)
        #expect(TextTruncation(unit: .page, keptUnits: 2, totalUnits: 4, coveredUnits: [1, 2]).summary == "pages 1-2 of 4")
    }
}
