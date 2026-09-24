import SwiftUI

/// Under a Chief of Staff reply that made a card: the card while it waits
/// (Do it, Edit, Later, No), then one line for what became of it. In the
/// pinned chat the List above holds the keyboard; in a Discuss chat, where
/// there is no List, the card takes it itself.
struct ToldCard: View {
    @Bindable var model: ChiefOfStaffModel
    let cardID: String
    /// The keyboard is on the cards (the window's `Focus.cards`).
    let hasKeyboard: Bool
    /// Discuss: the card is the keyboard's place, not the List's.
    var takesKeyboard = false
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }

    @FocusState private var cardFocused: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable(takesKeyboard && owns && !model.isEditingFocusedCard && !(model.laterMenu?.isPicking ?? false))
            .focusEffectDisabled()
            .focused($cardFocused)
            .onChange(of: owns) { _, has in
                if takesKeyboard, has, !model.isEditingFocusedCard { FocusRequest.apply($cardFocused) }
            }
            .onAppear {
                if takesKeyboard, owns, !model.isEditingFocusedCard { FocusRequest.apply($cardFocused) }
            }
            .onChange(of: cardFocused) { _, focused in
                if focused { onFocus(.cards) }
            }
    }

    /// The keyboard is on this card.
    private var owns: Bool { hasKeyboard && model.focusedCardID == cardID }

    @ViewBuilder
    private var content: some View {
        if let proposal = model.proposal(cardID) {
            if proposal.awaitsReview {
                PageNote(text: "Checking this card. It shows here when the check is done.")
            } else if proposal.isWaiting {
                WaitingProposalCard(model: model, proposal: proposal, hasKeyboard: hasKeyboard, onFocus: onFocus)
            } else {
                DecidedProposalLine(proposal: proposal) {}
            }
        } else {
            PageNote(text: "The card is not in the thread yet.")
        }
    }
}

/// Above the composer of a Discuss chat: what it discusses, and Tell Chief
/// of Staff (⇧⌘↩), which sends the draft, else the last question, to the
/// Chief of Staff about the card.
struct DiscussStrip: View {
    let model: ChiefOfStaffModel
    let cardID: String
    let isTelling: Bool
    let onTell: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            Text(about)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: House.Spacing.xs)
            if isTelling {
                Text(CosTellService.status)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize()
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                CardButton(title: "Tell Chief of Staff", keys: ["⇧", "⌘", "↩"], showsKeys: true, action: onTell)
                    .help("Send your draft, or your last message, to the Chief of Staff to act on")
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: House.Control.chip, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Discussing a Chief of Staff card")
    }

    private var about: String {
        guard let card = model.proposal(cardID) else { return "About a Chief of Staff card" }
        return "About: \(card.headline)"
    }
}

/// In the pinned chat's key strip: the card the next message is about, with
/// a way to clear it.
struct SubjectChip: View {
    let proposal: Proposal
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            Text("About: \(proposal.headline)")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not about this card")
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.chip)
        .background(Capsule().fill(House.ColorToken.chipFill))
        .help("Your next message is about this card. Esc clears it.")
    }
}
