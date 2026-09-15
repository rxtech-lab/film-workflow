import SwiftUI

/// An interactive gallery consumers can place in their own preview canvas.
@MainActor public struct PetPreviewGallery: View {
    @State private var mood: PetMood = .happy
    @State private var status: PetStatus = .replaying
    @State private var motion: PetMotion = .automatic
    @State private var animate = true
    @State private var frame = 0
    @State private var speed = 1.0
    @State private var message = "Recording Safari — Checkout"
    public init() {}
    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("Mood", selection: $mood) { ForEach(PetMood.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Status", selection: $status) { ForEach(PetStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Pose", selection: $motion) { ForEach(PetMotion.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            TextField("Message", text: $message)
            Toggle("Animate", isOn: $animate)
            HStack { Text("Speed"); Slider(value: $speed, in: 0.25...2); Text(speed, format: .number.precision(.fractionLength(2))) }
            if !animate { Stepper("Frame \(frame + 1) of 6", value: $frame, in: 0...5) }
            PetView(character: .cameraBuddy)
                .mood(mood).status(status).motion(motion).message(message)
                .size(120).animationFrame(animate ? nil : frame).animationSpeed(speed)
                .frame(height: 190)
        }.padding(24).frame(width: 650)
    }
}

#Preview("Camera · Interactive poses") { PetPreviewGallery() }

#Preview("Camera · Every animated pose") {
    ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(150)), count: 4), spacing: 24) {
            ForEach(PetMotion.allCases.filter { $0 != .automatic }, id: \.self) { motion in
                VStack { PetView().motion(motion).size(96).frame(height: 110); Text(motion.rawValue).font(.caption) }
            }
        }.padding(24)
    }.frame(width: 700, height: 360)
}

#Preview("Camera · Every mood") {
    HStack(spacing: 14) {
        ForEach(PetMood.allCases, id: \.self) { mood in
            VStack { PetView().mood(mood).motion(.idle).size(84); Text(mood.rawValue).font(.caption) }
        }
    }.padding(24)
}

#Preview("Camera · Recording states") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(190)), count: 3), spacing: 20) {
        ForEach(PetStatus.allCases, id: \.self) { status in
            PetView(state: PetState(status: status, message: status.rawValue.capitalized)).size(84).frame(height: 125)
        }
    }.padding(24)
}

#Preview("Camera · All still movement frames") {
    ScrollView([.horizontal, .vertical]) {
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(PetMotion.allCases.filter { $0 != .automatic }, id: \.self) { motion in
                GridRow {
                    Text(motion.rawValue).font(.caption).frame(width: 85, alignment: .leading)
                    ForEach(0..<6) { frame in PetView().motion(motion).animationFrame(frame).size(72) }
                }
            }
        }.padding(24)
    }.frame(width: 680, height: 720)
}

#Preview("Camera · Reduce Motion and messages") {
    HStack {
        PetView().status(.replaying).message("Recording Safari — Checkout").size(72).animated(false)
        PetView().status(.failed).message("Window unavailable. Choose another target.").size(72).animated(false)
        PetView().status(.paused).message("Paused").size(48).animated(false)
    }.padding(24)
}
