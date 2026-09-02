import Testing
import Foundation
@testable import QuickLaunch

@Suite("App paths")
@MainActor
struct AppPathsTests {
    @Test func applicationSupportDirectoryMatchesTheHistoricalHandBuiltPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent("Library/Application Support/Quick Launch")
        #expect(AppPaths.applicationSupportDirectory.path == legacy.path)

        let viaFileManager = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Quick Launch", isDirectory: true)
        #expect(AppPaths.applicationSupportDirectory.path == viaFileManager.path)
    }

    @Test func fileAndDirectoryHelpersKeepEveryStoreOnItsOldPath() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quick Launch")
        #expect(AppPaths.file("clipboard-history.json").path == base.appendingPathComponent("clipboard-history.json").path)
        #expect(AppPaths.file("translation-history.json").path
            == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Quick Launch/translation-history.json").path)
        #expect(AppPaths.directory("Screen History Soak").path == base.appendingPathComponent("Screen History Soak").path)
        #expect(AppPaths.directory("Screen History Soak").hasDirectoryPath)
        #expect(!AppPaths.file("launcher-usage.json").hasDirectoryPath)
    }

    @Test func storesUseTheSharedDirectory() {
        let base = AppPaths.applicationSupportDirectory.path
        #expect(LauncherUsageStore.defaultFileURL().path == base + "/launcher-usage.json")
        #expect(ScreenshotTextIndex.defaultStoreURL().path == base + "/screenshot-text-index.json")
        #expect(TranslationHistoryStore.defaultURL().path == base + "/translation-history.json")
        #expect(QuickHistoryStore.defaultFileURL().path == base + "/chat-history.json")
        #expect(SQLiteScreenHistoryStore.defaultDatabaseURL().path == base + "/screen-history.sqlite3")
        #expect(SQLiteScreenHistoryStore.defaultMediaDirectoryURL().path == base + "/Screen History Frames")
        #expect(ScreenHistoryCoastFreezeReceiptService.defaultReceiptDirectoryURLForTesting.path == base + "/Screen History Coast Freeze")
    }
}
