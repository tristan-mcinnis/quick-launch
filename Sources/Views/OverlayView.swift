import SwiftUI
import Combine
import HouseDesign

struct OverlayView: View {
    @Bindable var viewModel: QuickViewModel
    /// The composer's attachment tray. Passed down through the environment,
    /// so the Quick AI composer and Add Context pane find it.
    var tray: AttachmentTray? = nil
    @State private var quickAIComposerHeight = QuickAIView.composerRowHeight
    @State private var surfaceHeight = PanelSizing.quickAIHeight
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.attachmentTray) private var inheritedTray

    /// The tray passed in, else the environment's, else the view model's
    /// own: the composer's attachments always have a home.
    private var activeTray: AttachmentTray? { tray ?? inheritedTray ?? viewModel.attachmentTray }

    var body: some View {
        Group {
            if viewModel.isQuickAIPresented {
                // Quick AI replaces the launcher in place: its own header,
                // thread, and bottom composer, and no footer well. The whole
                // surface takes a drop.
                QuickAIView(viewModel: viewModel) { quickAIComposerHeight = $0 }
                    .attachmentDropTarget(activeTray)
            } else {
                rootSurface
            }
        }
        .environment(\.attachmentTray, activeTray)
        // Root search is exactly its measured width. Quick AI fills the
        // window, which the user can drag larger than 750 × 475: a fixed
        // width would pin the hosting view and stop the drag.
        .frame(
            minWidth: viewModel.isQuickAIPresented ? PanelSizing.panelWidth : viewModel.currentPanelWidth,
            maxWidth: viewModel.isQuickAIPresented ? .infinity : viewModel.currentPanelWidth,
            minHeight: rootSurfaceMinimumHeight,
            alignment: .top
        )
        .panelGlass()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { surfaceHeight = $0 }
        .overlay(alignment: viewModel.isQuickAIPresented ? .bottomTrailing : .topTrailing) {
            actionPopover
                .environment(\.composerPaneMaximumHeight, viewModel.isQuickAIPresented
                    ? max(0, surfaceHeight - quickAIComposerHeight - QuickAIView.headerHeight - House.Spacing.xs)
                    : nil)
        }
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .onAppear { focusInput() }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in focusInput() }
        .onChange(of: viewModel.launcherMatches.map(\.id)) { _, matches in
            if !matches.isEmpty { viewModel.announceCurrentLauncherSelection() }
        }
        .onChange(of: viewModel.launcherSelectionAnnouncementRevision) { _, _ in
            announceLauncherSelection(viewModel.launcherSelectionAnnouncement)
        }
        .onChange(of: viewModel.errorMessage) { _, error in
            guard let error, !error.isEmpty else { return }
            postAccessibilityAnnouncement("Error. \(error)", priority: .high)
        }
    }

    /// While a ⌘K pane floats over root search, the surface claims the whole
    /// window the panel was sized to. Without it a short surface (an empty
    /// catalog, one row) sits centred in a taller window and the pane, which
    /// hangs from the surface's top edge, runs off the bottom of the glass.
    private var rootSurfaceMinimumHeight: CGFloat? {
        guard !viewModel.isQuickAIPresented, viewModel.isItemActionPanePresented else { return nil }
        return viewModel.estimatedWindowHeight
    }

    /// Root search: the input row, the launcher list, the catalogs, and the
    /// footer well. Model answers never draw here; they live on the Quick AI
    /// surface, and a thread kept behind root search stays out of sight.
    /// The one answer root draws is a local one (math, a conversion, a date,
    /// a system fact), under the input row as v1.3.0 drew it.
    private var rootSurface: some View {
        VStack(spacing: 0) {
            // Input row: the Add Context control, a leading glyph, the field,
            // and one square menu button. No send circle and no accent
            // anywhere — Return sends.
            HStack(spacing: AQDesign.Space.row) {
                Button {
                    viewModel.toggleAddContextMenu()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(AQDesign.TypeToken.glyph)
                        .foregroundStyle(
                            viewModel.isAddContextMenuPresented
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textTertiary
                        )
                        .frame(width: House.Control.tile, height: House.Control.tile)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Context")
                .accessibilityValue(viewModel.isAddContextMenuPresented ? "Open" : "Closed")
                .help("Add context: a window, a selection, an area, or a screen (or type @)")

                Image(systemName: "magnifyingglass")
                    .font(AQDesign.TypeToken.glyph)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)

                // Single line, scrolling horizontally like Raycast. A
                // vertical-axis field capped at one line scrolled long text
                // upward until only the descenders were visible.
                TextField(
                    viewModel.inputPlaceholder,
                    text: $viewModel.input
                )
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.input)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submitResolvingFuzzyAlias() } }
                    .modifier(ComposerKeyRouting(viewModel: viewModel))
                    .onChange(of: viewModel.input) { _, newValue in
                        viewModel.resetApplicationSelection()
                        viewModel.noteInteraction()
                        viewModel.rootInputDidChange(newValue)
                        // Typing `@` opens the same Add Context menu the
                        // control left of the field does.
                        viewModel.addContextTriggerDidChange(newValue)
                    }
                    .disabled(viewModel.isStreaming)

                // Working / copied lives in the same slot; at rest the row
                // carries one control, the menu, exactly as the design does.
                if viewModel.isStreaming {
                    Button { viewModel.cancel() } label: {
                        ThinkingIndicator().frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop response")
                    .help("Working… press Escape to stop")
                } else if viewModel.justSaved {
                    Image(systemName: "square.and.arrow.down")
                        .font(AQDesign.TypeToken.input)
                        .foregroundStyle(AQDesign.ColorToken.success)
                        .accessibilityLabel("Saved to Screenshots")
                        .help("Saved to Screenshots")
                        .paneOpenTransition()
                } else if viewModel.justCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AQDesign.TypeToken.input)
                        .foregroundStyle(AQDesign.ColorToken.success)
                        .accessibilityLabel("Copied to clipboard")
                        .help("Copied to clipboard")
                        .paneOpenTransition()
                }

                moreMenu
            }
            .paneOpenAnimation(value: viewModel.justCopied)
            .paneOpenAnimation(value: viewModel.justSaved)
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(minHeight: AQDesign.inputHeight)

            if viewModel.launchSelection != nil {
                HouseDivider()
                LaunchSelectionStrip(viewModel: viewModel)
            }

            // The transform surface follows whatever source is active, not
            // only the launch-selection strip: an attached or clipboard
            // selection reaches the same chooser and argument field.
            if viewModel.hasTransformSource {
                Group {
                    if viewModel.isTransformChooserPresented {
                        Group {
                            HouseDivider()
                            TransformChooserPane(viewModel: viewModel)
                        }
                        .paneOpenTransition()
                    }
                }
                .paneOpenAnimation(value: viewModel.isTransformChooserPresented)
                if viewModel.isTransformArgumentFieldPresented {
                    HouseDivider()
                    TransformArgumentPane(viewModel: viewModel)
                }
            }

            if viewModel.isModelChooserPresented {
                HouseDivider()
                ModelChooserPane(viewModel: viewModel)
            }

            if viewModel.isCaptureChooserPresented {
                HouseDivider()
                CaptureChooserPane(viewModel: viewModel)
            }

            if viewModel.isAddContextMenuPresented {
                HouseDivider()
                AddContextPane(viewModel: viewModel)
            }

            Group {
                if ComposerAttachmentStrip.hasChips(viewModel: viewModel, tray: activeTray)
                    || activeTray?.notice != nil {
                    Group {
                        HouseDivider()
                        ComposerAttachmentStrip(viewModel: viewModel, tray: activeTray, sideInset: AQDesign.Space.panel)
                    }
                    .paneOpenTransition()
                }
            }
            .paneOpenAnimation(value: ComposerAttachmentStrip.hasChips(viewModel: viewModel, tray: activeTray))

            if !viewModel.isTransformChooserPresented,
               !viewModel.isTransformArgumentFieldPresented,
               !viewModel.isModelChooserPresented,
               !viewModel.isCaptureChooserPresented,
               !viewModel.isAddContextMenuPresented,
               (!viewModel.launcherMatches.isEmpty || (viewModel.isHistoryCatalog && viewModel.showsDetailPane)) {
                HouseDivider()
                if viewModel.launcherMatches.isEmpty {
                    Text(viewModel.input.isEmpty
                         ? (viewModel.catalogScope == .screenshots ? "Take a screenshot to see it here" : "Copy text or an image to see it here")
                         : "No matches. Try a different search.")
                        .font(House.TypeToken.body)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        // Same guardrail as the list block: fill the preview
                        // space when the display has it, shrink to the room
                        // when it does not, so the footer stays on screen.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(maxHeight: PanelSizing.launcherListMaximumHeight)
                        .layoutPriority(1)
                } else if viewModel.isGridCatalog {
                    if viewModel.catalogScope == .screenshots {
                        ScreenshotGridView(viewModel: viewModel)
                    } else {
                        EmojiGridView(viewModel: viewModel)
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        launcherList
                            .frame(width: viewModel.showsDetailPane ? PanelSizing.detailListWidth : nil)
                        if viewModel.showsDetailPane, let item = viewModel.detailItem {
                            Rectangle().fill(AQDesign.ColorToken.divider).frame(width: AQDesign.hairline)
                            // The ⌘K pane takes this column while it is open,
                            // so the preview withdraws rather than being left
                            // half-covered and cut mid-word behind the card.
                            if viewModel.isItemActionPanePresented {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                CatalogDetailPane(viewModel: viewModel, item: item)
                            }
                        }
                    }
                    // A fixed height here pushed the footer past the window's
                    // bottom edge on a short display, where the hung frame is
                    // capped to the room under the anchor. A flexible block
                    // takes what is left, so the list scrolls and the footer
                    // keeps the bottom edge.
                    .frame(
                        minHeight: 0,
                        maxHeight: viewModel.isHistoryCatalog && viewModel.showsDetailPane
                            ? PanelSizing.launcherListMaximumHeight : nil
                    )
                    .layoutPriority(1)
                }
            }

            // Saved-prompt autocomplete
            if !viewModel.isApplicationActionPanePresented,
               !viewModel.isCatalogActionPanePresented,
               !viewModel.isTransformChooserPresented,
               !viewModel.savedPromptMatches.isEmpty {
                HouseDivider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.savedPromptMatches) { match in
                        Button {
                            viewModel.complete(savedPrompt: match)
                        } label: {
                            HStack(spacing: 10) {
                                Text(viewModel.settings.savedPromptPrefix + match.alias)
                                    .font(AQDesign.TypeToken.codeLabel)
                                    .foregroundStyle(AQDesign.ColorToken.emphasis)
                                Text(match.prompt)
                                    .font(AQDesign.TypeToken.detail)
                                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let answer = viewModel.rootAnswer {
                HouseDivider()
                RootAnswerBlock(answer: answer)
            }

            // Error message
            if let error = viewModel.errorMessage {
                HouseDivider()
                HStack(spacing: AQDesign.Space.standard) {
                    Text(error)
                        .font(AQDesign.TypeToken.detail)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                    Spacer()
                    if viewModel.needsAccessibilityPermission {
                        Button("Open System Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                        .buttonStyle(InkButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            // Claimed height goes here, so the footer keeps the bottom edge
            // and everything above it keeps its own place.
            Spacer(minLength: 0)

            if viewModel.showsLauncherFooter {
                FooterWell { LauncherFooter(viewModel: viewModel) }
            }
        }
    }

    private func focusInput() {
        // The Quick AI composer owns focus while the surface is up; asking
        // the hidden root field would move nothing.
        guard !viewModel.isQuickAIPresented else { return }
        // A chooser with its own search field owns the keys while it is up.
        guard !viewModel.searchablePaneOwningFocus else { return }
        FocusRequest.apply($inputFocused)
    }

    private var actionPaneWidth: CGFloat {
        PanelSizing.itemActionPaneWidth(
            panelWidth: viewModel.currentPanelWidth,
            showsDetailPane: viewModel.showsDetailPane
        )
    }

    @ViewBuilder
    private var actionPopover: some View {
        Group {
            if viewModel.isItemActionPanePresented,
               let result = viewModel.focusedLauncherResult {
                ItemActionPane(viewModel: viewModel, result: result)
            } else if viewModel.isActionPalettePresented {
                QuickActionPalette(viewModel: viewModel)
            }
        }
        .frame(width: actionPaneWidth)
        // Chrome hugs the content: a `.frame(maxHeight:)` adopts the window's
        // proposal, so background applied outside it stretched into an empty
        // dark sheet whenever the window was tall.
        .panelGlass(radius: AQDesign.cardCornerRadius)
        .panelShadows()
        // At root the pane hangs from the input row; on the Quick AI
        // surface it hugs the composer, so the flexible frame fills the
        // surface's proposal and the palette sits at its bottom edge, not
        // over the header.
        .frame(
            maxHeight: PanelSizing.actionPaletteMaxHeight,
            alignment: viewModel.isQuickAIPresented ? .bottom : .top
        )
        // Below the input row and, when present, the attachment strip:
        // without the offset the pane covered the attachment preview. On the
        // Quick AI surface the pane floats above the bottom composer instead.
        .padding(
            .top,
            viewModel.isQuickAIPresented
                ? 0
                : PanelSizing.inputHeight
                    + (viewModel.hasPendingAttachment ? PanelSizing.attachmentHeight : 0)
        )
        .padding(.bottom, viewModel.isQuickAIPresented ? quickAIComposerHeight : 0)
        .padding(.trailing, House.Spacing.sm)
    }

    private func announceLauncherSelection(_ announcement: String) {
        guard !announcement.isEmpty else { return }
        postAccessibilityAnnouncement(announcement, priority: .medium)
    }

    private func postAccessibilityAnnouncement(
        _ announcement: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: priority.rawValue,
            ]
        )
    }

    private var launcherList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: launcherSectionTitle)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)

            SelectableListPane(
                items: viewModel.launcherMatches,
                selectedIndex: $viewModel.applicationSelectionIndex,
                scrollsToSelection: true,
                onActivate: { result in
                    Task { await viewModel.performLauncherResult(result) }
                }
            ) { index, result, isSelected in
                LauncherResultRow(
                    result: result,
                    isSelected: isSelected,
                    hotkey: viewModel.hotkey(for: result),
                    position: index + 1,
                    total: viewModel.launcherMatches.count,
                    showsTypeLabel: viewModel.showsRowTypeLabels
                )
                .padding(.horizontal, 10)
                .frame(minHeight: AQDesign.rowHeight, maxHeight: AQDesign.rowHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, AQDesign.Space.standard)
        .padding(.bottom, AQDesign.Space.standard)
        .frame(maxHeight: PanelSizing.launcherListMaximumHeight)
    }

    private var launcherSectionTitle: String {
        if let scope = viewModel.catalogScope { return scope.title }
        return viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Suggestions"
            : "Results"
    }

    private var moreMenu: some View {
        Menu {
            Button {
                viewModel.toggleActionPalette()
            } label: {
                Label("Actions…", systemImage: "wand.and.stars")
            }

            Divider()
            Button {
                viewModel.openCaptureChooser()
            } label: {
                Label(
                    "Capture…  \(ScreenshotKind.window.overlayKeyCaps(viewModel.shortcuts).joined())",
                    systemImage: "camera.viewfinder"
                )
            }
            ForEach(ScreenshotKind.allCases, id: \.rawValue) { kind in
                Button {
                    Task { await viewModel.attachScreenshot(kind, clearingInput: false) }
                } label: {
                    // The window key opens the chooser, so it is not shown
                    // beside this row's direct capture.
                    Label(
                        kind == .window
                            ? kind.title
                            : "\(kind.title)  \(kind.overlayKeyCaps(viewModel.shortcuts).joined())",
                        systemImage: kind.systemImage
                    )
                }
            }

            Divider()
            modelSubmenu

            Divider()
            ForEach(viewModel.chatMenuEntries) { entry in
                Button {
                    viewModel.performChatMenuEntry(entry)
                } label: {
                    Label(entry.menuTitle(viewModel.shortcuts), systemImage: entry.systemImage)
                }
                .disabled(!viewModel.isChatMenuEntryEnabled(entry))
            }

            Divider()
            Button {
                viewModel.overlayPresenter.openSettings()
            } label: {
                Label("Settings…", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(
                    viewModel.isActionPalettePresented
                        ? AQDesign.ColorToken.textPrimary
                        : AQDesign.ColorToken.textSecondary
                )
                .frame(width: House.Control.compact, height: House.Control.compact)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The tile is drawn around the menu, not inside its label: a
        // borderless menu style discards a background set on the label.
        .frame(width: House.Control.compact, height: House.Control.compact)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
        )
        .accessibilityLabel("More actions")
        .help("Actions, model, chats, and settings")
    }

    private var modelSubmenu: some View {
        Menu {
            Text("Using \(viewModel.activeModelDisplay)")
            Divider()
            ForEach(viewModel.settings.providers) { provider in
                Menu(provider.name) {
                    let models = viewModel.visibleModels(for: provider)
                    if models.isEmpty {
                        Button("Refresh models") {
                            Task { await viewModel.refreshModels(providerID: provider.id) }
                        }
                    } else {
                        ForEach(models, id: \.self) { model in
                            Button {
                                viewModel.selectModel(providerID: provider.id, model: model)
                            } label: {
                                if viewModel.isActiveModel(provider: provider, model: model) {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Refresh detected models") {
                Task { await viewModel.refreshDetectedModels() }
            }
            Button("Model settings…") {
                viewModel.overlayPresenter.openSettings()
            }
        } label: {
            Label("Model: \(viewModel.activeModelDisplay)", systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
