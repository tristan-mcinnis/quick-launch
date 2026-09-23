import Foundation
import UserNotifications

/// A tap on a Chief of Staff notification.
enum ChiefOfStaffNotificationChoice: Sendable, Equatable {
    case doIt(proposalID: String)
    case skip(proposalID: String)
    /// Open the pinned conversation, on this card when there is one.
    case open(proposalID: String?)
    /// Reply typed in the notification: a chat message about the card.
    case reply(proposalID: String?, text: String)
}

/// Posts Chief of Staff notices. The app's is `ChiefOfStaffNotifier`; tests
/// pass a fake and read what was posted.
@MainActor
protocol ChiefOfStaffNotifying: AnyObject {
    var onChoice: ((ChiefOfStaffNotificationChoice) -> Void)? { get set }
    /// Register the categories and ask for permission once.
    func prepare() async
    func post(_ notice: ChiefOfStaffNotice) async
}

/// The request a notice becomes, with no notification center: what the
/// tests check and what `ChiefOfStaffNotifier` posts.
struct ChiefOfStaffNotificationContent: Sendable, Equatable {
    var identifier: String
    var title: String
    var subtitle: String
    var body: String
    var category: String
    /// Cards from one project stack as one group.
    var threadIdentifier: String
    var proposalID: String?
    var urgency: ChiefOfStaffUrgency

    static let cardCategory = "chief-of-staff.card"
    /// A card with nothing to run (a health notice): Open and Reply only.
    static let noticeCategory = "chief-of-staff.notice"
    static let summaryCategory = "chief-of-staff.summary"
    static let doAction = "chief-of-staff.do"
    static let skipAction = "chief-of-staff.skip"
    static let openAction = "chief-of-staff.open"
    static let replyAction = "chief-of-staff.reply"
    static let proposalKey = "proposal"
    static let categories: Set<String> = [cardCategory, noticeCategory, summaryCategory]

    init(_ notice: ChiefOfStaffNotice) {
        title = "Chief of Staff"
        switch notice {
        case .card(let proposal, let urgency):
            identifier = "chief-of-staff.\(proposal.id)"
            subtitle = proposal.source
            body = proposal.headline
            category = proposal.isNotice ? Self.noticeCategory : Self.cardCategory
            threadIdentifier = proposal.project.isEmpty ? "chief-of-staff" : proposal.project
            proposalID = proposal.id
            self.urgency = urgency
        case .summary(let count, let sources, let urgency):
            identifier = "chief-of-staff.summary"
            subtitle = ""
            body = ChiefOfStaffNotificationRules.summaryBody(count: count, sources: sources)
            category = Self.summaryCategory
            threadIdentifier = "chief-of-staff"
            proposalID = nil
            self.urgency = urgency
        }
    }

    var interruptionLevel: UNNotificationInterruptionLevel {
        urgency == .timeSensitive ? .timeSensitive : .active
    }

    /// What a response to this category means.
    static func choice(action: String, proposalID: String?, text: String?) -> ChiefOfStaffNotificationChoice? {
        switch action {
        case doAction: proposalID.map { .doIt(proposalID: $0) }
        case skipAction: proposalID.map { .skip(proposalID: $0) }
        case replyAction:
            text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                .map { .reply(proposalID: proposalID, text: $0) }
        case UNNotificationDismissActionIdentifier: nil
        default: .open(proposalID: proposalID)
        }
    }
}

/// Chief of Staff notices as macOS notifications, from Quick Launch, the one
/// sender (the CLI's own banners stay quiet while `app.alive` is fresh).
@MainActor
final class ChiefOfStaffNotifier: ChiefOfStaffNotifying {
    var onChoice: ((ChiefOfStaffNotificationChoice) -> Void)?
    private let center = UNUserNotificationCenter.current()

    init() {
        UserNotificationRouter.shared.chiefOfStaff = { [weak self] action, proposalID, text in
            guard let choice = ChiefOfStaffNotificationContent.choice(
                action: action,
                proposalID: proposalID,
                text: text
            ) else { return }
            self?.onChoice?(choice)
        }
    }

    func prepare() async {
        let doIt = UNNotificationAction(identifier: ChiefOfStaffNotificationContent.doAction, title: "Do it")
        let skip = UNNotificationAction(identifier: ChiefOfStaffNotificationContent.skipAction, title: "Skip")
        let open = UNNotificationAction(
            identifier: ChiefOfStaffNotificationContent.openAction,
            title: "Open",
            options: [.foreground]
        )
        let reply = UNTextInputNotificationAction(
            identifier: ChiefOfStaffNotificationContent.replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Tell your chief of staff"
        )
        let existing = await center.notificationCategories()
            .filter { !ChiefOfStaffNotificationContent.categories.contains($0.identifier) }
        center.setNotificationCategories(existing.union([
            UNNotificationCategory(
                identifier: ChiefOfStaffNotificationContent.cardCategory,
                actions: [doIt, skip, open, reply],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: ChiefOfStaffNotificationContent.noticeCategory,
                actions: [open, reply],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: ChiefOfStaffNotificationContent.summaryCategory,
                actions: [open],
                intentIdentifiers: []
            ),
        ]))
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func post(_ notice: ChiefOfStaffNotice) async {
        let plan = ChiefOfStaffNotificationContent(notice)
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.subtitle = plan.subtitle
        content.body = plan.body
        content.categoryIdentifier = plan.category
        content.threadIdentifier = plan.threadIdentifier
        content.interruptionLevel = plan.interruptionLevel
        content.sound = .default
        if let proposalID = plan.proposalID {
            content.userInfo = [ChiefOfStaffNotificationContent.proposalKey: proposalID]
        }
        try? await center.add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil))
    }
}

/// The app's one `UNUserNotificationCenter` delegate. The center has one
/// delegate, and two features post: answer notices (AI Chat) and the Chief
/// of Staff. Each registers its handler here; a response goes to the owner
/// of its category.
@MainActor
final class UserNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UserNotificationRouter()

    /// A click on an answer notice.
    var answerOpen: (() -> Void)?
    /// Any response to a Chief of Staff notice: its action, the card it
    /// names, and the text of a Reply.
    var chiefOfStaff: ((_ action: String, _ proposalID: String?, _ text: String?) -> Void)?

    /// Become the center's delegate. Called once the app has a bundle.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let isChiefOfStaff = ChiefOfStaffNotificationContent.categories
            .contains(notification.request.content.categoryIdentifier)
        return isChiefOfStaff ? [.banner, .list, .sound] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Only strings cross to the main actor; the response stays here.
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let action = response.actionIdentifier
        let proposalID = content.userInfo[ChiefOfStaffNotificationContent.proposalKey] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if ChiefOfStaffNotificationContent.categories.contains(category) {
                self.chiefOfStaff?(action, proposalID, text)
            } else if action == UNNotificationDefaultActionIdentifier {
                self.answerOpen?()
            }
        }
    }
}
