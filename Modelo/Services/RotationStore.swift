import Foundation

/// Ordered list of up to 4 pinned model IDs (LMStudioModel.id, same key as
/// FavoritesStore). Slot index maps directly to ⌥1–⌥4. nil = empty slot.
@Observable @MainActor
final class RotationStore {
    private static let key = "rotationModelSlots"

    private(set) var slots: [String?] = [nil, nil, nil, nil]

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        slots = (0..<4).map { i in
            guard i < stored.count else { return nil }
            return stored[i].isEmpty ? nil : stored[i]
        }
    }

    // MARK: - Mutations

    func pin(_ modelID: String) {
        if slots.contains(modelID) { return }
        if let i = slots.firstIndex(where: { $0 == nil }) {
            slots[i] = modelID
        } else {
            slots[3] = modelID  // replace last slot when full
        }
        persist()
    }

    func unpin(_ modelID: String) {
        guard let i = slots.firstIndex(of: modelID) else { return }
        slots[i] = nil
        persist()
    }

    // MARK: - Queries

    func slot(for modelID: String) -> Int? {
        slots.firstIndex(of: modelID)
    }

    func isPinned(_ modelID: String) -> Bool {
        slots.contains(modelID)
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(slots.map { $0 ?? "" }, forKey: Self.key)
    }
}
