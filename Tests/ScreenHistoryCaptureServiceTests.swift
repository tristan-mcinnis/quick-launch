import CoreGraphics
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History Capture", .serialized)
struct ScreenHistoryCaptureServiceTests {
    @Test func explicitPermissionRequestUpdatesTheVisibleBlockerWithoutReadingPixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.target()],
            frames: [Self.frame()],
            isAuthorized: false
        )
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            sink: RecordingHistoryFrameSink()
        )

        #expect(await service.requestScreenRecordingAuthorization() == false)
        let status = await service.status()
        #expect(status.lastSkipReason == .screenRecordingNotAuthorized)
        #expect(status.metrics.screenRecordingBlockedCycles == 1)
        #expect(await source.permissionRequestCallCount == 1)
        #expect(await source.targetCallCount == 0)
        #expect(await source.captureCallCount == 0)
    }

    @Test func missingScreenRecordingPermissionStopsBeforeTargetOrPixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.target()],
            frames: [Self.frame()],
            isAuthorized: false
        )
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            sink: RecordingHistoryFrameSink()
        )

        await service.start()
        await service.runOneCycle()

        let status = await service.status()
        #expect(status.state == .stopped)
        #expect(status.lastSkipReason == .screenRecordingNotAuthorized)
        #expect(status.metrics.screenRecordingBlockedCycles == 1)
        #expect(await source.targetCallCount == 0)
        #expect(await source.captureCallCount == 0)
    }

    @Test func sinkFailureDoesNotClaimEmissionOrSuppressRetry() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.target(), Self.target()],
            frames: [Self.frame(), Self.frame()]
        )
        let sink = FailingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            sink: sink
        )

        await service.start()
        await service.runOneCycle()
        await service.runOneCycle()

        let status = await service.status()
        #expect(status.lastSkipReason == .storageFailure)
        #expect(status.metrics.storageFailures == 2)
        #expect(status.metrics.emittedFrames == 0)
        #expect(await source.captureCallCount == 2)
        #expect(await sink.callCount == 2)
        await service.stop()
    }

    @Test func captureIsDisabledByDefault() async {
        let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(source: source, sink: sink)

        await service.start()
        await service.runOneCycle()

        #expect(await service.status().state == .disabled)
        #expect(await source.targetCallCount == 0)
        #expect(await sink.frames.isEmpty)
    }

    @Test func ownAndConfiguredBundlesAreExcluded() async {
        let source = FakeHistoryFrameSource(targets: [
            Self.target(bundleIdentifier: ScreenHistoryCaptureConfiguration.ownBundleIdentifier),
            Self.target(bundleIdentifier: "com.example.private"),
        ], frames: [])
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let configuration = ScreenHistoryCaptureConfiguration(
            isEnabled: true,
            excludedBundleIdentifiers: ["COM.EXAMPLE.PRIVATE"]
        )
        let service = Self.service(
            configuration: configuration,
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()

        await service.runOneCycle()
        #expect(await service.status().lastSkipReason == .excludedBundleIdentifier(
            ScreenHistoryCaptureConfiguration.ownBundleIdentifier
        ))
        await service.runOneCycle()
        #expect(await service.status().lastSkipReason == .excludedBundleIdentifier("com.example.private"))
        #expect(await sink.frames.isEmpty)
        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await service.status().metrics.excludedFrames == 2)
        await service.stop()
    }

    @Test func unknownBundleIdentifierIsRefusedBeforeOCR() async {
        let source = FakeHistoryFrameSource(targets: [Self.target(bundleIdentifier: nil)], frames: [])
        let recognizer = FakeHistoryTextRecognizer(text: "secret")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()

        await service.runOneCycle()

        #expect(await service.status().lastSkipReason == .unknownBundleIdentifier)
        #expect(await service.status().metrics.unknownApplicationFrames == 1)
        #expect(await recognizer.callCount == 0)
        #expect(await source.captureCallCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func protectedWindowTitleIsRefusedBeforePixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.browserTarget(windowTitle: "Private Browsing")],
            frames: [Self.frame()]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await service.status().lastSkipReason == .protectedSurface)
        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func browserWithoutReadableURLIsRefusedBeforePixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.browserTarget(domain: nil, hasReadableURL: false)],
            frames: [Self.frame()]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await service.status().lastSkipReason == .protectedSurface)
        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func privateFocusedWebAreaTitleIsRefusedBeforePixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.browserTarget(windowTitle: "Search", pageTitle: "New Incognito Tab")],
            frames: [Self.frame()]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true, excludedDomains: []),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func mismatchedBrowserURLAndDomainAreRefusedBeforePixels() async {
        let target = ScreenHistoryCaptureTarget(
            windowIdentifier: 7,
            processIdentifier: 42,
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            windowTitle: "Research",
            pageURL: URL(string: "https://allowed.example/research"),
            domain: "different.example"
        )
        let source = FakeHistoryFrameSource(targets: [target], frames: [Self.frame()])
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true, excludedDomains: []),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func protectedDomainCategoriesAreRefusedBeforePixels() async {
        let domains = [
            "auth.example.com", "login.example.com", "checkout.example.com",
            "payment.example.com", "banking.example.com", "finance.example.com",
            "billing.example.com", "wallet.example.com",
        ]
        for domain in domains {
            let source = FakeHistoryFrameSource(
                targets: [Self.browserTarget(domain: domain)],
                frames: [Self.frame()]
            )
            let recognizer = FakeHistoryTextRecognizer(text: "must not run")
            let sink = RecordingHistoryFrameSink()
            let service = Self.service(
                configuration: .init(isEnabled: true, excludedDomains: []),
                source: source,
                recognizer: recognizer,
                sink: sink
            )
            await service.start()
            await service.runOneCycle()

            #expect(await service.status().lastSkipReason == .protectedSurface)
            #expect(await source.captureCallCount == 0)
            #expect(await recognizer.callCount == 0)
            #expect(await sink.frames.isEmpty)
            await service.stop()
        }
    }

    @Test func configuredDomainExclusionUsesExactAndSuffixMatching() async {
        let source = FakeHistoryFrameSource(
            targets: [
                Self.browserTarget(domain: "example.com"),
                Self.browserTarget(domain: "private.example.com"),
            ],
            frames: [Self.frame(), Self.frame()]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true, excludedDomains: ["EXAMPLE.COM."]),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()
        await service.runOneCycle()

        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        #expect(await service.status().metrics.excludedFrames == 2)
        await service.stop()
    }

    @Test func allKnownBrowsersAreRefusedBeforePixelsEvenWithAllowedMetadata() async {
        let browserSource = FakeHistoryFrameSource(
            targets: [Self.browserTarget(domain: "docs.example.org")],
            frames: [Self.frame()]
        )
        let browserRecognizer = FakeHistoryTextRecognizer(text: "browser")
        let browserSink = RecordingHistoryFrameSink()
        let browserService = Self.service(
            configuration: .init(isEnabled: true, excludedDomains: []),
            source: browserSource,
            recognizer: browserRecognizer,
            sink: browserSink
        )
        await browserService.start()
        await browserService.runOneCycle()

        let appSource = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let appRecognizer = FakeHistoryTextRecognizer(text: "application")
        let appSink = RecordingHistoryFrameSink()
        let appService = Self.service(
            configuration: .init(isEnabled: true),
            source: appSource,
            recognizer: appRecognizer,
            sink: appSink
        )
        await appService.start()
        await appService.runOneCycle()

        #expect(await browserSource.captureCallCount == 0)
        #expect(await browserRecognizer.callCount == 0)
        #expect(await browserSink.frames.isEmpty)
        #expect(await appSource.captureCallCount == 1)
        #expect(await appRecognizer.callCount == 1)
        #expect(await appSink.frames.count == 1)
        await browserService.stop()
        await appService.stop()
    }

    @Test func fileVaultOffAndUnknownRefuseStartBeforeReadingTheScreen() async {
        for status in [FileVaultStatus.off, .unknown] {
            let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
            let sink = RecordingHistoryFrameSink()
            let service = Self.service(
                configuration: .init(isEnabled: true),
                source: source,
                sink: sink,
                fileVaultStatus: status
            )

            await service.start()
            await service.runOneCycle()

            #expect(await service.status().state == .stopped)
            #expect(await service.status().fileVaultStatus == status)
            #expect(await source.targetCallCount == 0)
            #expect(await sink.frames.isEmpty)
        }
    }

    @Test func fileVaultOnAllowsExplicitStart() async {
        let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let recognizer = FakeHistoryTextRecognizer(text: "Recognized")
        let sink = RecordingHistoryFrameSink()
        let protectedSessionReader = FakeProtectedSessionReader(statuses: [.clear])
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink,
            fileVaultStatus: .on,
            protectedSessionReader: protectedSessionReader
        )

        await service.start()
        await service.runOneCycle()

        #expect(await service.status().state == .running)
        #expect(await source.targetCallCount == 1)
        #expect(await source.captureCallCount == 1)
        #expect(await recognizer.callCount == 1)
        #expect(await sink.frames.count == 1)
        #expect(await protectedSessionReader.callCount == 2)
        await service.stop()
    }

    @Test func protectedSessionStatesRefuseBeforeReadingTheFrontmostTarget() async {
        let protectedStates: [ScreenHistoryProtectedSessionStatus] = [
            .locked,
            .offConsole,
            .activeDisplayCapture,
            .unknown,
        ]
        for protectedState in protectedStates {
            let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
            let recognizer = FakeHistoryTextRecognizer(text: "must not run")
            let sink = RecordingHistoryFrameSink()
            let reader = FakeProtectedSessionReader(statuses: [protectedState])
            let service = Self.service(
                configuration: .init(isEnabled: true),
                source: source,
                recognizer: recognizer,
                sink: sink,
                protectedSessionReader: reader
            )

            await service.start()
            await service.runOneCycle()

            let status = await service.status()
            #expect(status.lastSkipReason == .protectedSession(protectedState))
            #expect(status.metrics.protectedSessionCycles == 1)
            switch protectedState {
            case .locked:
                #expect(status.metrics.lockedSessionCycles == 1)
            case .offConsole:
                #expect(status.metrics.offConsoleSessionCycles == 1)
            case .activeDisplayCapture:
                #expect(status.metrics.activeDisplayCaptureCycles == 1)
            case .unknown:
                #expect(status.metrics.unknownSessionCycles == 1)
            case .clear:
                Issue.record("Clear is not a protected state")
            }
            #expect(await source.targetCallCount == 0)
            #expect(await source.captureCallCount == 0)
            #expect(await recognizer.callCount == 0)
            #expect(await sink.frames.isEmpty)
            await service.stop()
        }
    }

    @Test func sessionIsCheckedAgainImmediatelyBeforePixelCapture() async {
        let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let reader = FakeProtectedSessionReader(statuses: [.clear, .activeDisplayCapture])
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink,
            protectedSessionReader: reader
        )

        await service.start()
        await service.runOneCycle()

        #expect(await source.targetCallCount == 1)
        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        #expect(await reader.callCount == 2)
        #expect(await service.status().lastSkipReason == .protectedSession(.activeDisplayCapture))
        #expect(await service.status().metrics.activeDisplayCaptureCycles == 1)
        await service.stop()
    }

    @Test func defaultScreenSharingAndRecordingAppsAreRefusedBeforePixels() async {
        let bundleIdentifiers = [
            "com.apple.ScreenSharing",
            "com.apple.RemoteDesktop",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.tencent.meeting",
            "com.apple.FaceTime",
            "com.obsproject.obs-studio",
            "com.microsoft.rdc.macos",
            "com.loom.desktop",
            "com.teamviewer.TeamViewer",
        ]
        for bundleIdentifier in bundleIdentifiers {
            let source = FakeHistoryFrameSource(
                targets: [Self.target(bundleIdentifier: bundleIdentifier)],
                frames: [Self.frame()]
            )
            let recognizer = FakeHistoryTextRecognizer(text: "must not run")
            let sink = RecordingHistoryFrameSink()
            let service = Self.service(
                configuration: .init(isEnabled: true, excludedBundleIdentifiers: []),
                source: source,
                recognizer: recognizer,
                sink: sink
            )

            await service.start()
            await service.runOneCycle()

            let normalized = bundleIdentifier.lowercased()
            #expect(await service.status().lastSkipReason == .excludedBundleIdentifier(normalized))
            #expect(await source.captureCallCount == 0)
            #expect(await recognizer.callCount == 0)
            #expect(await sink.frames.isEmpty)
            await service.stop()
        }
    }

    @Test func browserFamiliesIncludeCommonVariants() {
        for bundleIdentifier in [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview",
            "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser.nightly",
            "com.microsoft.edgemac.Beta", "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly", "net.imput.helium",
            "company.thebrowser.Browser", "company.thebrowser.Browser.beta",
            "company.thebrowser.dia", "com.operasoftware.Opera",
            "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi.snapshot",
            "com.kagi.kagimacOS",
        ] {
            #expect(ScreenHistoryPrivacyPolicy.isKnownBrowser(bundleIdentifier: bundleIdentifier))
        }
        #expect(!ScreenHistoryPrivacyPolicy.isKnownBrowser(bundleIdentifier: "com.apple.iWork.Keynote"))
    }

    @Test func addedBrowserFamiliesAreRefusedBeforePixels() async {
        for (bundleIdentifier, applicationName) in [
            ("company.thebrowser.Browser", "Arc"),
            ("company.thebrowser.dia", "Dia"),
            ("com.operasoftware.Opera", "Opera"),
            ("com.operasoftware.OperaGX", "Opera GX"),
            ("com.vivaldi.Vivaldi", "Vivaldi"),
            ("com.kagi.kagimacOS", "Orion"),
        ] {
            let source = FakeHistoryFrameSource(
                targets: [Self.browserTarget(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: applicationName
                )],
                frames: [Self.frame()]
            )
            let recognizer = FakeHistoryTextRecognizer(text: "must not run")
            let sink = RecordingHistoryFrameSink()
            let service = Self.service(
                configuration: .init(isEnabled: true, excludedDomains: []),
                source: source,
                recognizer: recognizer,
                sink: sink
            )
            await service.start()
            await service.runOneCycle()

            #expect(await service.status().lastSkipReason == .protectedSurface)
            #expect(await source.captureCallCount == 0)
            #expect(await recognizer.callCount == 0)
            #expect(await sink.frames.isEmpty)
            await service.stop()
        }
    }

    @Test func manifestWebHandlersIdentifyUnknownBrowserBeforePixels() async {
        let manifest: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["custom", " HTTPS "]],
            ],
        ]
        #expect(ScreenCaptureKitHistoryFrameSource.declaresWebURLHandling(in: manifest))
        #expect(!ScreenCaptureKitHistoryFrameSource.declaresWebURLHandling(in: [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["custom"]]],
        ]))

        let target = ScreenHistoryCaptureTarget(
            windowIdentifier: 7,
            processIdentifier: 42,
            bundleIdentifier: "org.example.unknown-web-client",
            applicationName: "Unknown Web Client",
            windowTitle: "Research",
            declaresWebURLHandling: true
        )
        let source = FakeHistoryFrameSource(targets: [target], frames: [Self.frame()])
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true, excludedDomains: []),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await service.status().lastSkipReason == .protectedSurface)
        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func passwordManagersStayExcludedWhenCustomListIsEmpty() {
        let configuration = ScreenHistoryCaptureConfiguration(
            isEnabled: true,
            excludedBundleIdentifiers: []
        )
        #expect(configuration.excludes("com.1password.1password"))
        #expect(configuration.excludes("com.apple.keychainaccess"))
        #expect(configuration.excludes("org.keepassxc.keepassxc"))
        #expect(configuration.excludes("com.objective-see.lulu"))
    }

    @Test func hardExcludedSecurityAppNeverReachesPixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.target(bundleIdentifier: "com.objective-see.lulu")],
            frames: [Self.frame()]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true, excludedBundleIdentifiers: []),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func safeDefaultDomainNeverReachesPixels() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.browserTarget(domain: "checkout.paypal.com")],
            frames: [Self.frame()]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        #expect(await source.captureCallCount == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func identicalConsecutiveFramesAreDroppedBeforeOCR() async {
        let frame = Self.frame(imageData: Data([1, 2, 3, 4]))
        let source = FakeHistoryFrameSource(
            targets: [Self.target(), Self.target()],
            frames: [frame, frame]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "Recognized")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()

        await service.runOneCycle()
        await service.runOneCycle()

        #expect(await recognizer.callCount == 1)
        #expect(await sink.frames.count == 1)
        #expect(await service.status().lastSkipReason == .unchanged)
        #expect(await service.status().metrics.duplicateFrames == 1)
        await service.stop()
    }

    @Test func inactivityPausesAndInputResumesCapture() async {
        let activity = FakeHistoryActivityReader(values: [500, 0])
        let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true, inactivityThresholdSeconds: 60),
            source: source,
            activity: activity,
            sink: sink
        )
        await service.start()

        await service.runOneCycle()
        #expect(await service.status().state == .pausedForInactivity)
        #expect(await source.targetCallCount == 0)

        await service.runOneCycle()
        #expect(await service.status().state == .running)
        #expect(await sink.frames.count == 1)
        #expect(await service.status().metrics.inactiveCycles == 1)
        await service.stop()
        #expect(await service.status().state == .stopped)
    }

    @Test func emittedFrameIsBoundedAndCadenceIsClamped() async {
        let longName = String(repeating: "A", count: 500)
        let longTitle = String(repeating: "T", count: 500)
        let longText = String(repeating: "x", count: 20_000)
        let source = FakeHistoryFrameSource(
            targets: [Self.target(applicationName: longName)],
            frames: [Self.frame(windowTitle: longTitle)]
        )
        let recognizer = FakeHistoryTextRecognizer(text: longText)
        let sink = RecordingHistoryFrameSink()
        let configuration = ScreenHistoryCaptureConfiguration(
            isEnabled: true,
            cadenceSeconds: 0.01,
            inactivityThresholdSeconds: 1
        )
        let service = Self.service(
            configuration: configuration,
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()
        await service.runOneCycle()

        let emitted = await sink.frames.first
        #expect(emitted?.applicationName.count == CapturedScreenFrame.maximumApplicationNameCharacters)
        #expect(emitted?.windowTitle?.count == CapturedScreenFrame.maximumWindowTitleCharacters)
        #expect(emitted?.recognizedText.count == CapturedScreenFrame.maximumOCRCharacters)
        #expect(await service.status().configuration.cadenceSeconds == 2)
        #expect(await service.status().configuration.inactivityThresholdSeconds == 60)
        #expect(await service.status().metrics.emittedFrames == 1)
        await service.stop()
    }

    @Test func oversizedPixelsNeverReachOCROrSink() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.target()],
            frames: [Self.frame(imageData: Data(
                repeating: 1,
                count: CapturedScreenFrame.maximumImageBytes + 1
            ))]
        )
        let recognizer = FakeHistoryTextRecognizer(text: "must not run")
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            recognizer: recognizer,
            sink: sink
        )
        await service.start()

        await service.runOneCycle()

        #expect(await service.status().lastSkipReason == .oversizedImage)
        #expect(await recognizer.callCount == 0)
        #expect(await sink.frames.isEmpty)
        await service.stop()
    }

    @Test func changingOptInDoesNotStartCaptureImplicitly() async {
        let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let service = Self.service(source: source)

        await service.updateConfiguration(.init(isEnabled: true))
        #expect(await service.status().state == .stopped)
        await service.runOneCycle()
        #expect(await source.targetCallCount == 0)

        await service.start()
        #expect(await service.status().state == .running)
        await service.stop()
        #expect(await service.status().state == .stopped)
    }

    @Test func selectedWindowIdentifierIsPreservedThroughPixelCapture() async {
        let source = FakeHistoryFrameSource(
            targets: [Self.target(windowIdentifier: 991)],
            frames: [Self.frame()]
        )
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source
        )

        await service.start()
        await service.runOneCycle()

        #expect(await source.capturedWindowIdentifiers == [991])
        await service.stop()
    }

    @Test func frontWindowMetadataChoosesOneVisibleWindowIdentity() {
        let smallBounds = CGRect(x: 0, y: 0, width: 20, height: 20).dictionaryRepresentation
        let normalBounds = CGRect(x: 10, y: 20, width: 900, height: 700).dictionaryRepresentation
        let rows: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: NSNumber(value: 42),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowNumber as String: NSNumber(value: 80),
                kCGWindowBounds as String: smallBounds,
            ],
            [
                kCGWindowOwnerPID as String: NSNumber(value: 77),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowNumber as String: NSNumber(value: 81),
                kCGWindowBounds as String: normalBounds,
            ],
            [
                kCGWindowOwnerPID as String: NSNumber(value: 42),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowNumber as String: NSNumber(value: 82),
                kCGWindowBounds as String: normalBounds,
                kCGWindowName as String: "Bound window",
            ],
        ]

        let selected = ScreenCaptureKitHistoryFrameSource.frontWindowMetadata(
            processIdentifier: 42,
            windowInfo: rows
        )

        #expect(selected == .init(identifier: 82, title: "Bound window"))
    }

    @Test func fileVaultIsRecheckedEveryCycleAndStopsBeforeTarget() async {
        for blockedStatus in [FileVaultStatus.off, .unknown] {
            let checker = FakeScreenHistorySecurityChecker(statuses: [.on, blockedStatus])
            let source = FakeHistoryFrameSource(
                targets: [Self.target()],
                frames: [Self.frame()]
            )
            let service = Self.service(
                configuration: .init(isEnabled: true),
                source: source,
                securityChecker: checker
            )

            await service.start()
            await service.runOneCycle()

            let status = await service.status()
            #expect(status.state == .stopped)
            #expect(status.fileVaultStatus == blockedStatus)
            #expect(status.lastSkipReason == .fileVault(blockedStatus))
            #expect(status.metrics.cycles == 1)
            #expect(status.metrics.fileVaultBlockedCycles == 1)
            #expect(await checker.callCount == 2)
            #expect(await source.targetCallCount == 0)
            #expect(await source.captureCallCount == 0)
        }
    }

    @Test func statusStreamEmitsStateAndMetricChangesWithoutPolling() async {
        let source = FakeHistoryFrameSource(targets: [Self.target()], frames: [Self.frame()])
        let sink = RecordingHistoryFrameSink()
        let service = Self.service(
            configuration: .init(isEnabled: true),
            source: source,
            sink: sink
        )
        let stream = await service.statusUpdates()
        var updates = stream.makeAsyncIterator()

        #expect(await updates.next()?.state == .stopped)
        await service.start()
        #expect(await updates.next()?.state == .running)
        await service.runOneCycle()
        let captured = await updates.next()
        #expect(captured?.state == .running)
        #expect(captured?.metrics.cycles == 1)
        #expect(captured?.metrics.emittedFrames == 1)
        await service.stop()
        #expect(await updates.next()?.state == .stopped)
    }

    private static func service(
        configuration: ScreenHistoryCaptureConfiguration = .init(),
        source: FakeHistoryFrameSource,
        activity: FakeHistoryActivityReader = .init(values: [0]),
        recognizer: FakeHistoryTextRecognizer = .init(text: "Recognized text"),
        sink: any ScreenHistoryFrameSink = RecordingHistoryFrameSink(),
        fileVaultStatus: FileVaultStatus = .on,
        securityChecker: FakeScreenHistorySecurityChecker? = nil,
        protectedSessionReader: FakeProtectedSessionReader = .init(statuses: [.clear])
    ) -> ScreenHistoryCaptureService {
        ScreenHistoryCaptureService(
            configuration: configuration,
            frameSource: source,
            activityReader: activity,
            textRecognizer: recognizer,
            sink: sink,
            securityChecker: securityChecker
                ?? FakeScreenHistorySecurityChecker(status: fileVaultStatus),
            protectedSessionReader: protectedSessionReader
        )
    }

    private static func target(
        windowIdentifier: CGWindowID = 7,
        bundleIdentifier: String? = "com.apple.iWork.Keynote",
        applicationName: String = "Keynote",
        windowTitle: String? = nil
    ) -> ScreenHistoryCaptureTarget {
        ScreenHistoryCaptureTarget(
            windowIdentifier: windowIdentifier,
            processIdentifier: 42,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowTitle: windowTitle
        )
    }

    private static func browserTarget(
        windowIdentifier: CGWindowID = 7,
        bundleIdentifier: String? = "com.apple.Safari",
        applicationName: String = "Safari",
        windowTitle: String? = "Research",
        domain: String? = "docs.example.org",
        hasReadableURL: Bool = true,
        pageTitle: String? = nil
    ) -> ScreenHistoryCaptureTarget {
        let pageURL = hasReadableURL ? domain.flatMap { URL(string: "https://\($0)/research") } : nil
        return ScreenHistoryCaptureTarget(
            windowIdentifier: windowIdentifier,
            processIdentifier: 42,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowTitle: windowTitle,
            pageURL: pageURL,
            domain: domain,
            pageTitle: pageTitle
        )
    }

    private static func frame(
        windowTitle: String? = "Example",
        imageData: Data = Data([1, 2, 3])
    ) -> ScreenHistoryRawFrame {
        ScreenHistoryRawFrame(
            capturedAt: Date(timeIntervalSince1970: 100),
            windowTitle: windowTitle,
            pixelWidth: 100,
            pixelHeight: 80,
            imageData: imageData
        )
    }
}

private actor FakeHistoryFrameSource: ScreenHistoryFrameSourcing {
    private var queuedTargets: [ScreenHistoryCaptureTarget]
    private var queuedFrames: [ScreenHistoryRawFrame]
    private(set) var targetCallCount = 0
    private(set) var captureCallCount = 0
    private(set) var permissionRequestCallCount = 0
    private(set) var capturedWindowIdentifiers: [CGWindowID] = []
    private let isAuthorized: Bool

    init(
        targets: [ScreenHistoryCaptureTarget],
        frames: [ScreenHistoryRawFrame],
        isAuthorized: Bool = true
    ) {
        queuedTargets = targets
        queuedFrames = frames
        self.isAuthorized = isAuthorized
    }

    func screenRecordingIsAuthorized() async -> Bool { isAuthorized }

    func requestScreenRecordingAuthorization() async -> Bool {
        permissionRequestCallCount += 1
        return isAuthorized
    }

    func frontmostWindowTarget() async -> ScreenHistoryCaptureTarget? {
        targetCallCount += 1
        return queuedTargets.isEmpty ? nil : queuedTargets.removeFirst()
    }

    func captureWindow(for target: ScreenHistoryCaptureTarget) async throws -> ScreenHistoryRawFrame? {
        captureCallCount += 1
        capturedWindowIdentifiers.append(target.windowIdentifier)
        return queuedFrames.isEmpty ? nil : queuedFrames.removeFirst()
    }
}

private actor FakeHistoryActivityReader: ScreenHistoryActivityReading {
    private var values: [TimeInterval]

    init(values: [TimeInterval]) {
        self.values = values
    }

    func secondsSinceLastInput() async -> TimeInterval {
        values.isEmpty ? 0 : values.removeFirst()
    }
}

private actor FakeHistoryTextRecognizer: ScreenHistoryTextRecognizing {
    let text: String
    private(set) var callCount = 0

    init(text: String) {
        self.text = text
    }

    func recognizeText(in imageData: Data) async -> String {
        callCount += 1
        return text
    }
}

private actor RecordingHistoryFrameSink: ScreenHistoryFrameSink {
    private(set) var frames: [CapturedScreenFrame] = []

    func receive(_ frame: CapturedScreenFrame) async throws {
        frames.append(frame)
    }
}

private actor FailingHistoryFrameSink: ScreenHistoryFrameSink {
    private(set) var callCount = 0

    func receive(_ frame: CapturedScreenFrame) async throws {
        callCount += 1
        throw LocalSQLiteError.execute("synthetic sink failure")
    }
}

private actor FakeScreenHistorySecurityChecker: ScreenHistorySecurityChecking {
    private var statuses: [FileVaultStatus]
    private let fallbackStatus: FileVaultStatus
    private(set) var callCount = 0

    init(status: FileVaultStatus) {
        statuses = [status]
        fallbackStatus = status
    }

    init(statuses: [FileVaultStatus]) {
        self.statuses = statuses
        fallbackStatus = statuses.last ?? .unknown
    }

    func fileVaultStatus() async -> FileVaultStatus {
        callCount += 1
        return statuses.isEmpty ? fallbackStatus : statuses.removeFirst()
    }
}

private actor FakeProtectedSessionReader: ScreenHistoryProtectedSessionReading {
    private var statuses: [ScreenHistoryProtectedSessionStatus]
    private let fallbackStatus: ScreenHistoryProtectedSessionStatus
    private(set) var callCount = 0

    init(statuses: [ScreenHistoryProtectedSessionStatus]) {
        self.statuses = statuses
        fallbackStatus = statuses.last ?? .unknown
    }

    func protectedSessionStatus() async -> ScreenHistoryProtectedSessionStatus {
        callCount += 1
        return statuses.isEmpty ? fallbackStatus : statuses.removeFirst()
    }
}
