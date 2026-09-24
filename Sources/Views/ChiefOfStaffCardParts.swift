import SwiftUI

/// More like this / Less like this: two quiet glyphs on every card. The one
/// given is filled; the keys show while the card has the keyboard.
struct FeedbackButtons: View {
    let feedback: String?
    var showsKeys = false
    let onMore: () -> Void
    let onLess: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            glyph(feedback == "more" ? "hand.thumbsup.fill" : "hand.thumbsup", label: "More like this", key: "=", action: onMore)
            glyph(feedback == "less" ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Less like this", key: "-", action: onLess)
        }
    }

    private func glyph(_ symbol: String, label: String, key: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: House.Spacing.xxs) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(width: House.Control.keyCap, height: House.Control.keyCap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(label) (⌘\(key))")
            .accessibilityLabel(label)
            if showsKeys {
                KeyCapGroup(keys: ["⌘", key]).accessibilityHidden(true)
            }
        }
    }
}

/// The reviewer's line on an escalated card: a status dot, "Reviewer", and
/// its reason. The dot is never alone.
struct ReviewLine: View {
    let review: Proposal.Review

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            StatusDot(color: House.ColorToken.warning)
            Text("Reviewer")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text(review.reason.isEmpty ? "Asked for your decision." : review.reason)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .help(review.model.isEmpty ? "" : "Reviewed by \(review.model)")
    }
}

/// The morning brief, pinned first in TODAY: its lines as written, and one
/// Got it.
struct MorningCard: View {
    let proposal: Proposal
    @Bindable var state: ProposalCardState
    let isFocused: Bool
    var feedback: FeedbackButtons?
    let onGotIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(spacing: House.Spacing.xs) {
                SectionLabel(text: "Morning")
                if let created = proposal.created {
                    Text(created, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                Spacer(minLength: 0)
                OfflineMark(proposal: proposal)
                if let feedback { feedback }
            }
            Text(proposal.headline)
                .font(House.TypeToken.heading)
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if proposal.message != proposal.headline {
                Text(proposal.message)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if state.isRunning {
                Text("Running…")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
            } else {
                CardButton(title: "Got it", keys: ["⌘", "↩"], showsKeys: isFocused, prominent: true, action: onGotIt)
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .strokeBorder(isFocused ? House.ColorToken.strokeStrong : House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Morning brief: \(proposal.headline)")
    }
}

/// A meeting card: who, the project, when it starts, and the open items.
struct MeetingCard: View {
    let proposal: Proposal
    @Bindable var state: ProposalCardState
    let isFocused: Bool
    var now: Date = .now
    var feedback: FeedbackButtons?
    let onGotIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                Image(systemName: "person.2")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                Text(startsLine)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .monospacedDigit()
                if let location = proposal.location {
                    Text(location)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                if !proposal.source.isEmpty {
                    Text(proposal.source)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                OfflineMark(proposal: proposal)
                if let feedback { feedback }
            }
            Text(proposal.headline)
                .font(House.TypeToken.heading)
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !proposal.attendees.isEmpty {
                Text("With " + proposal.attendees.joined(separator: ", "))
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if proposal.message != proposal.headline {
                Text(proposal.message)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(proposal.actions.enumerated()), id: \.offset) { index, action in
                ActionLine(number: index + 1, action: action)
            }
            RunStateLine(proposal: proposal)
            if !state.isRunning && proposal.canDoIt {
                // Its open items run as any card's do; with none, it is read.
                CardButton(
                    title: proposal.isNotice ? "Got it" : "Do it",
                    keys: ["⌘", "↩"],
                    showsKeys: isFocused,
                    prominent: true,
                    action: onGotIt
                )
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.surfaceRaised)
                .houseShadow(AQDesign.Shadow.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .strokeBorder(isFocused ? House.ColorToken.strokeStrong : House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting: \(proposal.headline), \(startsLine)")
    }

    /// "Starts in 12 min", "Started 3 min ago", or the time.
    private var startsLine: String {
        guard let starts = proposal.starts else { return "Meeting" }
        return MeetingCard.startsPhrase(starts, now: now)
    }

    static func startsPhrase(_ starts: Date, now: Date) -> String {
        let minutes = Int((starts.timeIntervalSince(now) / 60).rounded())
        switch minutes {
        case 1...90: return "Starts in \(minutes) min"
        case 0: return "Starts now"
        case -90 ..< 0: return "Started \(-minutes) min ago"
        default: return "At " + starts.formatted(date: .omitted, time: .shortened)
        }
    }
}

/// After a Do it: "Always do this for <project>?" ⌘Y yes, esc no.
struct RungOfferStrip: View {
    let offer: ChiefOfStaffModel.RungOffer
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: House.Spacing.sm) { question; Spacer(minLength: House.Spacing.xs); buttons }
            VStack(alignment: .leading, spacing: House.Spacing.xs) { question; HStack(spacing: House.Spacing.sm) { buttons } }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous).fill(House.ColorToken.surfaceTint))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Always do this for \(offer.project)?")
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
            Text("Always do this for \(offer.project)?")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text(Array(Set(offer.types)).sorted().joined(separator: ", ") + " run without asking. It shows as FYI, with Undo.")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        CardButton(title: "Always", keys: ["⌘", "Y"], showsKeys: true, prominent: true, action: onYes)
        CardButton(title: "Not now", keys: ["esc"], showsKeys: true, action: onNo)
    }
}

/// ⌘- on a card: "Less like this" and an optional one-line why.
struct LessPromptView: View {
    @Bindable var model: ChiefOfStaffModel
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        if let prompt = model.lessPrompt {
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                Text("Less like this: \(model.proposal(prompt.proposalID)?.headline ?? "")")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(2)
                CardField(prompt: "Why, in one line (optional)", text: whyBinding, lines: 1...1)
                    .focused($focused)
                    .onSubmit { model.submitLess() }
                HStack(spacing: House.Spacing.xs) {
                    CardButton(title: "Send", keys: ["↩"], showsKeys: true, prominent: true) { model.submitLess() }
                    CardButton(title: "Cancel", keys: ["esc"], showsKeys: true) { model.lessPrompt = nil }
                }
            }
            .padding(House.Spacing.sm)
            .raisedCard(radius: AQDesign.cardCornerRadius, fill: AQDesign.ColorToken.raisedSurface)
            .houseShadow(AQDesign.Shadow.card)
            .onAppear { FocusRequest.apply($focused) }
            .onChange(of: focused) { _, now in if now { onFocus(.form) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Less like this")
        }
    }

    private var whyBinding: Binding<String> {
        Binding(get: { model.lessPrompt?.why ?? "" }, set: { model.lessPrompt?.why = $0 })
    }
}

/// A card whose actions are running now, or whose run a crash cut off:
/// a status dot and the words, never colour alone.
struct RunStateLine: View {
    let proposal: Proposal

    var body: some View {
        if proposal.outcomeUnknown {
            line(House.ColorToken.warning, "Did not finish; check before retrying.")
        } else if proposal.isRunning {
            line(House.ColorToken.textTertiary, "Running now.")
        }
    }

    private func line(_ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            StatusDot(color: color)
            Text(text)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Two of Tristan's learnings in one scope disagree: both texts, each
/// with Forget (1 or 2 while the card has the keyboard). A forget closes
/// the card.
struct LearningsConflictCard: View {
    let proposal: Proposal
    let isFocused: Bool
    var scope: String
    let onForget: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(spacing: House.Spacing.xs) {
                SectionLabel(text: "Learnings")
                Text(scope)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                Spacer(minLength: 0)
            }
            Text(proposal.headline)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let conflict = proposal.conflict {
                ForEach(Array(conflict.texts.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                        ActionNumber(number: index + 1)
                        Text(text)
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: House.Spacing.xs)
                        CardButton(title: "Forget", keys: ["\(index + 1)"], showsKeys: isFocused) { onForget(index) }
                    }
                }
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .strokeBorder(isFocused ? House.ColorToken.strokeStrong : House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Learnings disagree: \(proposal.headline)")
    }
}

/// A quiet "Made offline" on a morning or meeting card the online model did
/// not write; who made it (a local model or plain rules) on hover.
struct OfflineMark: View {
    let proposal: Proposal

    var body: some View {
        if proposal.madeOffline {
            Text("Made offline")
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textTertiary)
                .help(help)
                .accessibilityLabel("Made offline, \(help)")
        }
    }

    private var help: String {
        switch proposal.madeBy {
        case "local-model": "by the local model"
        case "rules": "by rules, with no model"
        default: "without the online model"
        }
    }
}
