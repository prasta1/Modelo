import XCTest
@testable import Modelo

@MainActor
final class RotationStoreTests: XCTestCase {
    private let udKey = "rotationModelSlots"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    // MARK: Initial state

    func test_slots_defaultToFourNilSlots() {
        let store = RotationStore()
        XCTAssertEqual(store.slots, [nil, nil, nil, nil])
    }

    // MARK: pin

    func test_pin_fillsFirstEmptySlot() {
        let store = RotationStore()
        store.pin("model-a")
        XCTAssertEqual(store.slots[0], "model-a")
        XCTAssertNil(store.slots[1])
    }

    func test_pin_fillsSlotsInOrder() {
        let store = RotationStore()
        store.pin("a"); store.pin("b"); store.pin("c")
        XCTAssertEqual(store.slots[0], "a")
        XCTAssertEqual(store.slots[1], "b")
        XCTAssertEqual(store.slots[2], "c")
        XCTAssertNil(store.slots[3])
    }

    func test_pin_idempotentWhenAlreadyPinned() {
        let store = RotationStore()
        store.pin("model-a")
        store.pin("model-a")
        let pinned = store.slots.compactMap { $0 }
        XCTAssertEqual(pinned, ["model-a"])
    }

    func test_pin_replacesLastSlotWhenFull() {
        let store = RotationStore()
        store.pin("a"); store.pin("b"); store.pin("c"); store.pin("d")
        store.pin("e")
        XCTAssertEqual(store.slots[3], "e")
        XCTAssertEqual(store.slots[0], "a") // earlier slots untouched
    }

    // MARK: unpin

    func test_unpin_clearsSlot() {
        let store = RotationStore()
        store.pin("model-a")
        store.unpin("model-a")
        XCTAssertNil(store.slots[0])
    }

    func test_unpin_noopForUnknownModel() {
        let store = RotationStore()
        store.pin("model-a")
        store.unpin("nonexistent")
        XCTAssertEqual(store.slots[0], "model-a")
    }

    func test_unpin_leavesOtherSlotsIntact() {
        let store = RotationStore()
        store.pin("a"); store.pin("b"); store.pin("c")
        store.unpin("b")
        XCTAssertEqual(store.slots[0], "a")
        XCTAssertNil(store.slots[1])
        XCTAssertEqual(store.slots[2], "c")
    }

    // MARK: slot(for:)

    func test_slot_returnsCorrectIndex() {
        let store = RotationStore()
        store.pin("a"); store.pin("b")
        XCTAssertEqual(store.slot(for: "a"), 0)
        XCTAssertEqual(store.slot(for: "b"), 1)
    }

    func test_slot_returnsNilForUnpinnedModel() {
        let store = RotationStore()
        XCTAssertNil(store.slot(for: "ghost"))
    }

    // MARK: isPinned

    func test_isPinned_trueAfterPin() {
        let store = RotationStore()
        store.pin("model-x")
        XCTAssertTrue(store.isPinned("model-x"))
    }

    func test_isPinned_falseForUnpinnedModel() {
        let store = RotationStore()
        XCTAssertFalse(store.isPinned("model-y"))
    }

    func test_isPinned_falseAfterUnpin() {
        let store = RotationStore()
        store.pin("model-z")
        store.unpin("model-z")
        XCTAssertFalse(store.isPinned("model-z"))
    }

    // MARK: persistence

    func test_persistsAcrossInstances() {
        let store1 = RotationStore()
        store1.pin("persistent")

        let store2 = RotationStore()
        XCTAssertEqual(store2.slots[0], "persistent")
    }

    func test_unpinPersistsAcrossInstances() {
        let store1 = RotationStore()
        store1.pin("a"); store1.pin("b")
        store1.unpin("a")

        let store2 = RotationStore()
        XCTAssertNil(store2.slots[0])
        XCTAssertEqual(store2.slots[1], "b")
    }
}
