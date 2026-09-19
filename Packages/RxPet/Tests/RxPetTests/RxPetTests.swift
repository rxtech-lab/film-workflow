import AppKit
import ImageIO
import Testing
@testable import RxPet

@MainActor @Suite struct RxPetTests {
    @Test func companionStaysBesideWindowsAndWithinEachDisplay() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let size = CGSize(width: 210, height: 130)
        let centered = CGRect(x: -1100, y: 100, width: 500, height: 450)
        let right = PetOverlayPresenter.origin(target: centered, visibleFrame: screen, size: size)
        #expect(right.x == centered.maxX + 8)
        let first = CGRect(origin: right, size: size)
        let second = CGRect(origin: PetOverlayPresenter.origin(target: centered, visibleFrame: screen, size: size, avoiding: [first]), size: size)
        #expect(!first.intersects(second))
        #expect(screen.contains(second))
        let nearRight = CGRect(x: -800, y: 100, width: 750, height: 450)
        let left = PetOverlayPresenter.origin(target: nearRight, visibleFrame: screen, size: size)
        #expect(left.x + size.width == nearRight.minX - 8)
        for target in [screen, centered, nearRight, CGRect(x: -1400, y: -500, width: 1350, height: 500)] {
            let origin = PetOverlayPresenter.origin(target: target, visibleFrame: screen, size: size)
            #expect(screen.contains(CGRect(origin: origin, size: size)))
        }
    }
    @Test func followingAMovingWindowSnapsAndStillWalks() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let presenter = PetOverlayPresenter()
        defer { presenter.dismiss() }
        let start = CGRect(x: 300, y: 300, width: 500, height: 400)
        presenter.prepare(state: PetState(status: .recording, message: "Window"), target: start, visibleFrame: screen)
        presenter.reveal()
        let settled = try! #require(presenter.placementFrame)

        // The window is dragged: an animation restarted every tick would leave
        // the pet permanently behind, so the move has to land immediately.
        let moved = start.offsetBy(dx: 120, dy: -60)
        presenter.move(target: moved, visibleFrame: screen, animated: false)
        let followed = try! #require(presenter.placementFrame)
        #expect(followed != settled)
        #expect(followed.origin == PetOverlayPresenter.origin(target: moved, visibleFrame: screen, size: followed.size))
        // Snapping is still travelling, so the legs keep moving.
        #expect(presenter.isWalking)
    }

    @Test func placementIsPublishedEvenWhenThePetHoldsStill() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let presenter = PetOverlayPresenter()
        defer { presenter.dismiss() }
        let target = CGRect(x: 300, y: 300, width: 500, height: 400)
        presenter.prepare(state: PetState(status: .recording), target: target, visibleFrame: screen)
        presenter.reveal()
        let first = try! #require(presenter.placementFrame)
        // Other overlays ride against this, so a no-op move must not blank it.
        presenter.move(target: target, visibleFrame: screen, animated: false)
        #expect(presenter.placementFrame == first)
    }

    @Test func independentOverrides() {
        var state = PetState(mood: .happy, status: .failed, motion: .walking)
        #expect(state.resolvedMood == .happy); #expect(state.resolvedMotion == .walking)
        state.motion = .automatic; #expect(state.resolvedMotion == .failure)
        state.mood = nil; #expect(state.resolvedMood == .concerned)
        for status in PetStatus.allCases { #expect(PetState(status: status).resolvedMotion != .automatic) }
    }
    @Test func resourcesAndRegisteredFrames() throws {
        let character = PetCharacter.cameraBuddy
        let manifest = try JSONDecoder().decode(PetAnimationManifest.self, from: Data(contentsOf: #require(character.manifestURL)))
        #expect(manifest.version == 1); #expect(manifest.frames.count == 48)
        for row in 0..<8 {
            var hashes = Set<Data>()
            for column in 0..<6 {
                let frame = try #require(PetSpriteCache.frame(character, row: row, column: column))
                #expect(frame.width == manifest.frameWidth); #expect(frame.height == manifest.frameHeight)
                let bytes = try #require(frame.dataProvider?.data); hashes.insert(bytes as Data)
            }
            #expect(hashes.count > 2, "Every animation must contain actual movement frames")
            for mood in PetMood.allCases {
                #expect(PetSpriteCache.frame(character, row: row, column: 0, mood: mood) != nil)
            }
        }
    }
    @Test func exportVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["RX_PET_QA"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1200, height: 1680)
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.darkGray.cgColor); context.fill(CGRect(origin: .zero, size: size))
        for row in 0..<8 {
            let mood: PetMood? = row == 0 ? nil : [.focused, .curious, .sleepy, .happy, .neutral, .happy, .concerned][row - 1]
            let url = URL(fileURLWithPath: directory).appendingPathComponent("motion-\(row).gif")
            let gif = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 6, nil))
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for column in 0..<6 {
                let frame = try #require(PetSpriteCache.frame(.cameraBuddy, row: row, column: column, mood: mood))
                context.draw(frame, in: CGRect(x: column * 200, y: (7 - row) * 210, width: 200, height: 210))
                CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: PetSpriteCache.durations(.cameraBuddy, row: row)[column]]] as CFDictionary)
            }
            #expect(CGImageDestinationFinalize(gif))
        }
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("contact.png"))
    }
}
