import Foundation

/// Why the model chooser is open. The same keyboard list serves both keys:
/// `⇧⌘R` regenerates the last answer on the picked model, **Change Model**
/// makes it the active model without answering again.
enum ModelChooserPurpose: Equatable, Sendable {
    case regenerate
    case change

    /// Header line of the open chooser.
    var title: String {
        switch self {
        case .regenerate: "Regenerate with Model"
        case .change: "Change Model"
        }
    }

    /// What Return does, spelled out beside the key cap.
    var confirmTitle: String {
        switch self {
        case .regenerate: "Regenerate"
        case .change: "Use Model"
        }
    }
}

/// One row of the model chooser: a provider and one of the models it may
/// offer. Only models that pass `ModelCatalogService.visibleModels` ever
/// reach here, so a model the user turned off is never a choice.
struct ModelChooserOption: Identifiable, Equatable, Sendable {
    let providerID: UUID
    let providerName: String
    let model: String

    var id: String { providerID.uuidString + "\u{1F}" + model }
    var title: String { model }
    var detail: String { providerName }
}
