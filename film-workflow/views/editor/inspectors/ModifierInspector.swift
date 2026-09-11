import SwiftUI
import VideoEditorCore
import VideoEffectsCore
import VideoEffectsUI

enum ModifierInspectorSelection: Equatable {
    case catalog(ModifierDragItem)
    case effects(UUID)
    case transition(UUID)

    var tabID: String {
        switch self {
        case .catalog(let item): return item.kind == .effect ? "effects" : "transition"
        case .effects: return "effects"
        case .transition: return "transition"
        }
    }
}

struct ModifierInspector: View {
    let selection: ModifierInspectorSelection
    let sequence: SequenceProject?
    @Environment(\.undoManager) private var undoManager
    @State private var errorMessage: String?

    var body: some View {
        Form {
            switch selection {
            case .catalog(let item): catalog(item)
            case .effects(let clipID): effects(clipID)
            case .transition(let id): transition(id)
            }
        }
        .formStyle(.grouped)
        .alert("Couldn’t edit", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func catalog(_ item: ModifierDragItem) -> some View {
        if let definition = ModifierCatalog.standard.definition(item) {
            Section {
                ModifierThumbnail(item: item).frame(maxHeight: 140)
                Text(definition.name).font(.headline)
                Text(definition.summary).foregroundStyle(.secondary)
            }
            Section("Parameters") {
                ModifierParameterEditor(definition: definition, parameters: .constant(definition.defaults)).disabled(true)
                Text(item.kind == .effect ? "Drag onto a timeline clip to apply and adjust this effect." : "Drag onto a clip’s start, end, or a shared boundary to apply this transition.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func effects(_ clipID: UUID) -> some View {
        if let sequence, let clip = sequence.timeline.clip(id: clipID) {
            if clip.effects.isEmpty { Text("Drag an effect onto this clip to get started.").foregroundStyle(.secondary) }
            ForEach(Array(clip.effects.enumerated()), id: \.element.id) { index, instance in
                let definition = ModifierCatalog.standard.effect(instance.definitionID)
                Section(definition?.name ?? "Unavailable Effect") {
                    if let definition {
                        ModifierThumbnail(item: .init(kind: .effect, definitionID: instance.definitionID), parameters: instance.parameters).frame(maxHeight: 140)
                        Text(definition.summary).font(.caption).foregroundStyle(.secondary)
                        ModifierParameterEditor(definition: definition, parameters: Binding(get: {
                            sequence.timeline.clip(id: clipID)?.effects.first { $0.id == instance.id }?.parameters ?? instance.parameters
                        }, set: { value in editEffect(clipID, instance.id) { $0.parameters = value } }))
                    } else {
                        Text("\(instance.definitionID) is unavailable. Disable or remove it before exporting.").foregroundStyle(.orange)
                    }
                    Toggle("Enabled", isOn: Binding(get: {
                        sequence.timeline.clip(id: clipID)?.effects.first { $0.id == instance.id }?.isEnabled ?? false
                    }, set: { value in editEffect(clipID, instance.id) { $0.isEnabled = value } }))
                    HStack {
                        Button { reorder(clipID, index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move effect earlier")
                        Button { reorder(clipID, index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == clip.effects.count - 1).help("Move effect later")
                        Spacer()
                        Button("Remove", role: .destructive) {
                            edit("Remove Effect") { timeline in
                                try TimelineEditor.update(&timeline, clipID: clipID) { $0.effects.removeAll { $0.id == instance.id } }
                            }
                        }
                    }
                }
            }
        } else { Text("Select a clip to inspect its effects.").foregroundStyle(.secondary) }
    }

    @ViewBuilder private func transition(_ id: UUID) -> some View {
        if let sequence, let instance = sequence.timeline.transitions.first(where: { $0.id == id }) {
            let definition = ModifierCatalog.standard.transition(instance.definitionID)
            Section(definition?.name ?? "Unavailable Transition") {
                if let definition {
                    ModifierThumbnail(item: .init(kind: .transition, definitionID: instance.definitionID), parameters: instance.parameters).frame(maxHeight: 140)
                    Text(definition.summary).font(.caption).foregroundStyle(.secondary)
                    ModifierParameterEditor(definition: definition, parameters: Binding(get: {
                        sequence.timeline.transitions.first { $0.id == id }?.parameters ?? instance.parameters
                    }, set: { value in editTransition(id) { $0.parameters = value } }))
                } else {
                    Text("\(instance.definitionID) is unavailable. Disable or remove it before exporting.").foregroundStyle(.orange)
                }
                TransitionDurationField(duration: instance.duration, fps: sequence.fps) { duration in
                    editTransition(id) { $0.duration = duration }
                }
                Toggle("Enabled", isOn: Binding(get: { sequence.timeline.transitions.first { $0.id == id }?.isEnabled ?? false },
                                                set: { value in editTransition(id) { $0.isEnabled = value } }))
                if instance.attachment.isPair { Text("These clips move together. Remove the transition to unlink them.").font(.caption).foregroundStyle(.secondary) }
                Button("Remove Transition", role: .destructive) { edit("Remove Transition") { TimelineEditor.removeTransition(&$0, id: id) } }
            }
        } else { Text("Select a transition on the timeline.").foregroundStyle(.secondary) }
    }

    private func edit(_ name: String, _ change: (inout Timeline) throws -> Void) {
        guard let sequence else { return }
        var timeline = sequence.timeline
        do { try change(&timeline); sequence.editTimeline(timeline, undoManager: undoManager, actionName: name) }
        catch { errorMessage = error.localizedDescription }
    }
    private func editEffect(_ clipID: UUID, _ id: UUID, _ change: (inout EffectInstance) -> Void) {
        edit("Edit Effect") { timeline in
            try TimelineEditor.update(&timeline, clipID: clipID) { clip in
                if let index = clip.effects.firstIndex(where: { $0.id == id }) { change(&clip.effects[index]) }
            }
        }
    }
    private func editTransition(_ id: UUID, _ change: (inout TransitionInstance) -> Void) {
        edit("Edit Transition") { try TimelineEditor.updateTransition(&$0, id: id, change) }
    }
    private func reorder(_ clipID: UUID, _ from: Int, _ to: Int) {
        edit("Reorder Effects") { timeline in
            try TimelineEditor.update(&timeline, clipID: clipID) { clip in
                guard clip.effects.indices.contains(from), clip.effects.indices.contains(to) else { return }
                clip.effects.swapAt(from, to)
            }
        }
    }
}

private struct TransitionDurationField: View {
    let duration: Double
    let fps: Int
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        LabeledContent("Duration (seconds)") {
            TextField("Duration", text: $text).labelsHidden().accessibilityLabel("Duration (seconds)")
                .multilineTextAlignment(.trailing).frame(width: 80).focused($focused)
                .onSubmit { save() }
                .onChange(of: focused) { _, value in if !value { save() } }
                .onAppear { reset() }.onChange(of: duration) { _, _ in reset() }
        }
    }
    private func reset() { text = duration.formatted(.number.precision(.fractionLength(0...4)).locale(Locale(identifier: "en_US_POSIX"))) }
    private func save() {
        if let value = Double(text), value.isFinite { commit(value) }
        reset()
    }
}
