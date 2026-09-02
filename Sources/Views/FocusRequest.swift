import SwiftUI

/// Moves keyboard focus to a `@FocusState` field after the current layout
/// pass settles. Setting the binding synchronously inside `onAppear` or an
/// `onChange` handler is often ignored because the field is not yet in the
/// responder chain; one yield lets SwiftUI attach it first.
enum FocusRequest {
    @MainActor
    static func apply(_ focused: FocusState<Bool>.Binding) {
        Task { @MainActor in
            await Task.yield()
            focused.wrappedValue = true
        }
    }
}
