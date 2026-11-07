import Foundation

/// A fresh, empty defaults store for one test. The absolute temp path as suite
/// name puts the plist in the temp folder, not ~/Library/Preferences, where
/// cfprefsd keeps every suite's file even after removePersistentDomain.
func makeUserDefaults() -> UserDefaults {
    UserDefaults(suiteName: NSTemporaryDirectory() + "quicklaunch-test-\(UUID().uuidString)")!
}
