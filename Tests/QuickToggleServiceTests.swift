import Foundation
import Testing
@testable import QuickLaunch

/// Argument plans only. Nothing here runs a toggle on the machine.
@Suite("Quick toggles")
struct QuickToggleServiceTests {
    private static let shellMetacharacters = ["&&", ";", "|", "$", "`"]

    // MARK: - Catalog fields

    @Test func everyToggleHasTitleDetailKeywordsAndSymbol() {
        for toggle in QuickToggle.allCases {
            #expect(!toggle.title.isEmpty, "\(toggle) title")
            #expect(!toggle.detail.isEmpty, "\(toggle) detail")
            #expect(!toggle.keywords.isEmpty, "\(toggle) keywords")
            #expect(!toggle.systemImage.isEmpty, "\(toggle) systemImage")
        }
    }

    @Test func identifiersAreUniqueAndMatchRawValues() {
        let ids = QuickToggle.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids == QuickToggle.allCases.map(\.rawValue))
        #expect(QuickToggle.allCases.count == 8)
    }

    @Test func keywordsAreLowerCase() {
        for toggle in QuickToggle.allCases {
            #expect(toggle.keywords == toggle.keywords.lowercased(), "\(toggle)")
        }
    }

    @Test func titlesMatchTheSpec() {
        #expect(QuickToggle.toggleDarkMode.title == "Toggle Dark Mode")
        #expect(QuickToggle.lockScreen.title == "Lock Screen")
        #expect(QuickToggle.emptyTrash.title == "Empty Trash")
        #expect(QuickToggle.ejectAllDisks.title == "Eject All Disks")
        #expect(QuickToggle.toggleHiddenFiles.title == "Toggle Hidden Files")
        #expect(QuickToggle.toggleDesktopIcons.title == "Toggle Desktop Icons")
        #expect(QuickToggle.sleepDisplay.title == "Sleep Display")
        #expect(QuickToggle.startScreenSaver.title == "Start Screen Saver")
    }

    @Test func onlyEmptyTrashIsDestructive() {
        #expect(QuickToggle.allCases.filter(\.isDestructive) == [.emptyTrash])
    }

    @Test func automationPermissionMarksTheAppleScriptToggles() {
        let needing = Set(QuickToggle.allCases.filter(\.needsAutomationPermission))
        #expect(needing == [.toggleDarkMode, .lockScreen, .emptyTrash, .ejectAllDisks])
        for toggle in QuickToggle.allCases {
            let usesOsascript = QuickToggleService.plan(for: toggle).contains { $0.executable == QuickToggleService.osascript }
            #expect(usesOsascript == toggle.needsAutomationPermission, "\(toggle)")
        }
    }

    // MARK: - Plans

    @Test func darkModePlanIsOneFixedAppleScript() {
        #expect(QuickToggleService.plan(for: .toggleDarkMode) == [
            ProcessPlan(
                executable: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"]
            )
        ])
    }

    @Test func lockScreenPlanSendsControlCommandQ() {
        #expect(QuickToggleService.plan(for: .lockScreen) == [
            ProcessPlan(
                executable: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"]
            )
        ])
    }

    @Test func emptyTrashPlanTalksToFinder() {
        #expect(QuickToggleService.plan(for: .emptyTrash) == [
            ProcessPlan(executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"Finder\" to empty the trash"])
        ])
    }

    @Test func ejectAllDisksPlanTalksToFinder() {
        #expect(QuickToggleService.plan(for: .ejectAllDisks) == [
            ProcessPlan(
                executable: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Finder\" to eject (every disk whose ejectable is true)"]
            )
        ])
    }

    @Test func hiddenFilesPlanFlipsTheCurrentValueThenRestartsFinder() {
        let shown = QuickToggleService.plan(for: .toggleHiddenFiles, currentState: ["AppleShowAllFiles": true])
        #expect(shown == [
            ProcessPlan(executable: "/usr/bin/defaults", arguments: ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", "false"]),
            ProcessPlan(executable: "/usr/bin/killall", arguments: ["Finder"]),
        ])
        let hidden = QuickToggleService.plan(for: .toggleHiddenFiles, currentState: ["AppleShowAllFiles": false])
        #expect(hidden.first?.arguments == ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"])
    }

    @Test func hiddenFilesMissingKeyMeansHiddenSoThePlanShowsThem() {
        let plan = QuickToggleService.plan(for: .toggleHiddenFiles)
        #expect(plan.first?.arguments.last == "true")
        #expect(plan.count == 2)
    }

    @Test func desktopIconsPlanFlipsAndDefaultsToShown() {
        let missing = QuickToggleService.plan(for: .toggleDesktopIcons)
        #expect(missing == [
            ProcessPlan(executable: "/usr/bin/defaults", arguments: ["write", "com.apple.finder", "CreateDesktop", "-bool", "false"]),
            ProcessPlan(executable: "/usr/bin/killall", arguments: ["Finder"]),
        ])
        let hidden = QuickToggleService.plan(for: .toggleDesktopIcons, currentState: ["CreateDesktop": false])
        #expect(hidden.first?.arguments.last == "true")
    }

    @Test func sleepDisplayUsesPmset() {
        #expect(QuickToggleService.plan(for: .sleepDisplay) == [
            ProcessPlan(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])
        ])
    }

    @Test func screenSaverOpensTheEngineByName() {
        #expect(QuickToggleService.plan(for: .startScreenSaver) == [
            ProcessPlan(executable: "/usr/bin/open", arguments: ["-a", "ScreenSaverEngine"])
        ])
    }

    @Test func everyPlanUsesAbsoluteExecutablesAndNoShellMetacharacters() {
        for toggle in QuickToggle.allCases {
            for state in [[:], ["AppleShowAllFiles": true, "CreateDesktop": false]] {
                let plan = QuickToggleService.plan(for: toggle, currentState: state)
                #expect(!plan.isEmpty, "\(toggle)")
                for step in plan {
                    #expect(step.executable.hasPrefix("/usr/bin/"), "\(toggle) \(step.executable)")
                    for argument in step.arguments {
                        for token in Self.shellMetacharacters {
                            #expect(!argument.contains(token), "\(toggle) argument '\(argument)' contains \(token)")
                        }
                    }
                }
            }
        }
    }

    @Test func plansIgnoreUnrelatedStateKeys() {
        let plan = QuickToggleService.plan(for: .toggleDarkMode, currentState: ["AppleShowAllFiles": true, "anything": false])
        #expect(plan == QuickToggleService.plan(for: .toggleDarkMode))
    }

    // MARK: - State parsing and failures

    @Test func defaultsOutputParsesAsBool() {
        #expect(QuickToggleService.parseDefaultsBool("1\n") == true)
        #expect(QuickToggleService.parseDefaultsBool("0") == false)
        #expect(QuickToggleService.parseDefaultsBool("YES") == true)
        #expect(QuickToggleService.parseDefaultsBool("false\n") == false)
        #expect(QuickToggleService.parseDefaultsBool("") == nil)
        #expect(QuickToggleService.parseDefaultsBool("garbage") == nil)
    }

    @Test func successfulStepHasNoFailureMessage() {
        let step = QuickToggleService.plan(for: .sleepDisplay)[0]
        #expect(QuickToggleService.failureMessage(for: step, status: 0, stderr: "") == nil)
    }

    @Test func blockedAppleScriptGetsTheAutomationHint() {
        let step = QuickToggleService.plan(for: .toggleDarkMode)[0]
        let message = QuickToggleService.failureMessage(
            for: step,
            status: 1,
            stderr: "execution error: Not authorized to send Apple events to System Events. (-1743)"
        )
        #expect(message?.contains("Privacy & Security › Automation") == true)
        let notAllowed = QuickToggleService.failureMessage(for: step, status: 1, stderr: "Quick Launch is not allowed to send keystrokes.")
        #expect(notAllowed?.contains("Automation") == true)
    }

    @Test func otherFailuresReportTheToolAndFirstStderrLine() {
        let step = QuickToggleService.plan(for: .toggleHiddenFiles)[1]
        let message = QuickToggleService.failureMessage(for: step, status: 1, stderr: "No matching processes\nsecond line")
        #expect(message == "killall failed: No matching processes")
        let silent = QuickToggleService.failureMessage(for: step, status: 2, stderr: "")
        #expect(silent == "killall exited with status 2.")
        let osa = QuickToggleService.plan(for: .emptyTrash)[0]
        #expect(QuickToggleService.failureMessage(for: osa, status: 1, stderr: "syntax error")?.contains("Automation") == false)
    }
}
