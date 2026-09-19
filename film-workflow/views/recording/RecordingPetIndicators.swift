import AppKit
import RxPet

struct RecordingPetTarget: Identifiable {
    let id: String
    let name: String
    /// AppKit desktop coordinates.
    let frame: CGRect
}

@MainActor final class RecordingPetIndicators {
    private var pets: [String: PetOverlayPresenter] = [:]
    private var finishTask: Task<Void, Never>?
    var windowIDs: Set<CGWindowID> { Set(pets.values.compactMap(\.windowID)) }
    /// Where a given pet currently sits, so other overlays can ride beside it.
    func placementFrame(for id: String) -> CGRect? {
        guard let pet = pets[id], pet.isRevealed else { return nil }
        return pet.placementFrame
    }

    func prepare(targets: [RecordingPetTarget]) {
        finishTask?.cancel(); finishTask = nil
        hide()
        let wanted = Set(targets.map(\.id))
        for id in Array(pets.keys) where !wanted.contains(id) {
            if let windowID = pets[id]?.windowID {
                RecordingSources.shared.excludedWindowIDs.remove(windowID)
                RecordingSources.shared.passThroughWindowIDs.remove(windowID)
            }
            pets.removeValue(forKey: id)?.dismiss()
        }
        var occupied: [CGRect] = []
        for target in targets {
            let pet = pets[target.id] ?? PetOverlayPresenter()
            pet.prepare(state: PetState(status: .preparing, message: target.name), target: target.frame, visibleFrame: visibleFrame(for: target.frame))
            pet.move(target: target.frame, visibleFrame: visibleFrame(for: target.frame), animated: false, avoiding: occupied)
            if let frame = pet.placementFrame { occupied.append(frame) }
            pets[target.id] = pet
            if let id = pet.windowID {
                RecordingSources.shared.excludedWindowIDs.insert(id)
                RecordingSources.shared.passThroughWindowIDs.insert(id)
            }
        }
    }

    func update(targets: [RecordingPetTarget], status: PetStatus, mood: PetMood?, message: String?, appliedExclusions: Set<CGWindowID>, requiresExclusion: Bool) {
        let wanted = Set(targets.map(\.id))
        for (id, pet) in pets where !wanted.contains(id) { pet.hide() }
        var occupied: [CGRect] = []
        for target in targets {
            guard let pet = pets[target.id] else { continue }
            guard let windowID = pet.windowID,
                  !requiresExclusion || appliedExclusions.contains(windowID) else { pet.hide(); continue }
            let label: String
            switch status {
            case .paused: label = "Paused"
            case .failed: label = "Needs attention"
            case .preparing: label = "Preparing"
            case .waiting: label = "Waiting"
            default: label = "Recording"
            }
            let detail = message.map { "\(target.name) · \($0)" } ?? target.name
            pet.update(state: PetState(mood: mood, status: status, message: "\(label) · \(detail)"))
            pet.move(target: target.frame, visibleFrame: visibleFrame(for: target.frame), avoiding: occupied)
            if let frame = pet.placementFrame { occupied.append(frame) }
            pet.reveal()
        }
    }

    /// The fast path: position only. Everything that rebuilds the sprite —
    /// labels, status, reveal — stays on the slower `update`.
    func follow(targets: [RecordingPetTarget], moving: Set<String>) {
        var occupied: [CGRect] = []
        for target in targets {
            guard let pet = pets[target.id], pet.isRevealed else { continue }
            // A target that moved since the last tick is being dragged, so the
            // pet snaps to it; a settled target animates its walk instead.
            pet.move(target: target.frame, visibleFrame: visibleFrame(for: target.frame),
                     animated: !moving.contains(target.id), avoiding: occupied)
            if let frame = pet.placementFrame { occupied.append(frame) }
        }
    }

    func finish(success: Bool) {
        for pet in pets.values {
            pet.update(state: PetState(status: success ? .completed : .failed, message: success ? "Take saved!" : "Recording needs attention"))
            pet.reveal()
        }
        finishTask?.cancel()
        if success {
            finishTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }
    func hide() { pets.values.forEach { $0.hide() } }
    func dismiss() {
        finishTask?.cancel(); finishTask = nil
        for id in windowIDs {
            RecordingSources.shared.excludedWindowIDs.remove(id)
            RecordingSources.shared.passThroughWindowIDs.remove(id)
        }
        pets.values.forEach { $0.dismiss() }; pets = [:]
    }
    private func visibleFrame(for target: CGRect) -> CGRect {
        NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(target), b = rhs.frame.intersection(target)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }?.visibleFrame ?? target
    }
}
