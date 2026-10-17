import Foundation
import HouseChatCore
import Testing
@testable import QuickLaunch

@Suite("State saved by removed features")
struct RemovedFeatureStateTests {
    @Test func settingsWrittenWithRemovedFeatureKeysStillLoad() throws {
        let json = """
        {
          "hotkeyKeyCode": 36,
          "autoCopy": false,
          "hasSeenWelcome": true,
          "quickAIClarifyingQuestionsEnabled": true,
          "emojiSkinTone": 3,
          "colorFormat": "rgb",
          "colorHistoryLimit": 120,
          "launcherItemConfigurations": [
            {"kind": "emoji", "itemID": "emoji-1f600", "isPinned": true},
            {"kind": "color", "itemID": "ff8800ff", "alias": "orange"},
            {"kind": "snippet", "itemID": "sig", "alias": "sg"}
          ]
        }
        """
        let settings = try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))

        #expect(settings.hotkeyKeyCode == 36, "keys of kept settings still apply")
        #expect(!settings.autoCopy)
        let ids = settings.launcherItemConfigurations.map(\.id)
        #expect(ids.contains("snippet:sig"), "records of kept kinds survive")
        #expect(!ids.contains { $0.hasPrefix("emoji:") || $0.hasPrefix("color:") },
                "records of the removed kinds are dropped")

        let resaved = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: resaved) as? [String: Any])
        for key in ["hasSeenWelcome", "quickAIClarifyingQuestionsEnabled", "emojiSkinTone", "colorFormat", "colorHistoryLimit"] {
            #expect(object[key] == nil, "\(key) is not written back")
        }
    }

    @Test func aSavedChatMessageThatCarriedAQuestionCardStillDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "role": "assistant",
          "content": "Which folder?",
          "askUserQuestion": {
            "id": "\(UUID().uuidString)",
            "question": "Which folder?",
            "options": [{"label": "Work"}, {"label": "Personal"}],
            "selectedIndex": 1
          }
        }
        """
        let message = try JSONDecoder().decode(QuickMessage.self, from: Data(json.utf8))
        #expect(message.content == "Which folder?")
        #expect(message.role == .assistant)
    }

    @Test func anArchivedTurnWithAQuestionCardPayloadStillRebuildsItsMessage() throws {
        var payload = AppPayload(namespace: ChatArchive.namespace)
        payload["askUserQuestion"] = .object([
            "question": .string("Which city?"),
            "options": .array([.object(["label": .string("Lima")]), .object(["label": .string("Cusco")])]),
        ])
        let turn = TurnRecord(
            id: UUID().uuidString,
            role: .assistant,
            text: "Which city?",
            appPayload: payload
        )

        let message = try #require(ChatArchive.legacyMessage(for: turn))
        #expect(message.content == "Which city?")
        #expect(message.role == .assistant)
    }
}
