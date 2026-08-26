import Foundation
import Testing
@testable import QuickLaunch

/// Emoji & Symbols search, and the skin tone applied to the emoji that take one.
@Suite("Emoji catalog", .serialized)
@MainActor
struct EmojiSkinToneTests {

    @Test func theCatalogParsesWithNamesAndKeywords() {
        let items = EmojiCatalog.items
        #expect(items.count > 1_000)
        let joy = items.first { $0.value == "\u{1F602}" }
        #expect(joy?.title == "Face with Tears of Joy")
        #expect(joy?.keywords.contains("lol") == true)
        #expect(joy?.kind == .emoji)
    }

    @Test func everyItemHasAStableIdentifier() {
        let ids = Set(EmojiCatalog.items.map(\.itemID))
        #expect(ids.count == EmojiCatalog.items.count, "duplicate ids would break pins and favourites")
    }

    @Test func searchFindsAnEmojiByNameAndByKeyword() {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        vm.enterCatalog(.emoji)

        vm.input = "tears of joy"
        #expect(vm.catalogMatches.contains { $0.value == "\u{1F602}" })

        vm.input = "lol"
        #expect(vm.catalogMatches.contains { $0.value == "\u{1F602}" })
    }

    @Test func aSkinToneIsAppliedToTheEmojiThatAcceptOne() {
        let thumbsUp = "\u{1F44D}"
        #expect(EmojiCatalog.applyingSkinTone(3, to: thumbsUp) == "\u{1F44D}\u{1F3FD}")
        #expect(EmojiCatalog.applyingSkinTone(5, to: thumbsUp) == "\u{1F44D}\u{1F3FF}")
    }

    @Test func toneZeroAndUnsupportedGlyphsAreLeftAlone() {
        let thumbsUp = "\u{1F44D}"
        let rocket = "\u{1F680}"
        #expect(EmojiCatalog.applyingSkinTone(0, to: thumbsUp) == thumbsUp)
        #expect(EmojiCatalog.applyingSkinTone(4, to: rocket) == rocket)
        #expect(EmojiCatalog.applyingSkinTone(4, to: "\u{2764}") == "\u{2764}")
    }

    @Test func anExistingToneIsReplacedRatherThanDoubled() {
        let mediumThumbsUp = "\u{1F44D}\u{1F3FD}"
        #expect(EmojiCatalog.applyingSkinTone(1, to: mediumThumbsUp) == "\u{1F44D}\u{1F3FB}")
        #expect(EmojiCatalog.applyingSkinTone(0, to: mediumThumbsUp) == "\u{1F44D}")
    }

    @Test func theCatalogCarriesTheChosenToneWithoutChangingIdentifiers() {
        let plain = EmojiCatalog.items
        let toned = EmojiCatalog.items(skinTone: 5)
        #expect(toned.count == plain.count)
        #expect(zip(plain, toned).allSatisfy { $0.itemID == $1.itemID }, "pins must survive a tone change")

        let thumbsUpID = plain.first { $0.value == "\u{1F44D}" }?.itemID
        let tonedThumbsUp = toned.first { $0.itemID == thumbsUpID }
        #expect(tonedThumbsUp?.value == "\u{1F44D}\u{1F3FF}")
    }

    @Test func theViewModelServesTheTonedCatalog() {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        vm.settings.emojiSkinTone = 2
        vm.enterCatalog(.emoji)
        vm.input = "thumbs up"

        let match = vm.catalogMatches.first { $0.title.lowercased().contains("thumbs up") }
        #expect(match?.value == "\u{1F44D}\u{1F3FC}")

        vm.settings.emojiSkinTone = 0
        let plain = vm.catalogMatches.first { $0.title.lowercased().contains("thumbs up") }
        #expect(plain?.value == "\u{1F44D}")
    }
}
