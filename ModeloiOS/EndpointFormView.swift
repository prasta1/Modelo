import SwiftUI

/// Add/edit form for one endpoint (stub; filled in by the next task).
struct EndpointFormView: View {
    @State var draft: EndpointDraft
    let existing: Server?

    init(draft: EndpointDraft, existing: Server?) {
        _draft = State(initialValue: draft)
        self.existing = existing
    }

    var body: some View { Text(draft.label) }
}
