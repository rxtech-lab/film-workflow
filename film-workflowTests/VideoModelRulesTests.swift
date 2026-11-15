import Testing
@testable import film_workflow

@Suite("Google video model rules")
struct VideoModelRulesTests {
    @Test func omniResolutionsAndDuration() {
        let family = VeoModelFamily.from("gemini-omni-1.2-flash")
        #expect(family == .omni12)
        #expect(family.resolutions.contains(.r360p))
        #expect(family.durations(resolution: .r4k, usingReferenceImages: true).map(\.seconds) == Array(3...15))
        #expect(family.durations(resolution: .r4k, usingReferenceImages: false, interpolating: true).map(\.seconds) == Array(3...10))
        #expect(!family.supportsSeed)
        #expect(!family.supportsAudio)
        #expect(family.maxReferenceImages == 6)
    }
    @Test func earlierOmniAndVeoLimits() {
        #expect(VeoModelFamily.from("gemini-omni-1.1-flash").baseDurations.map(\.seconds) == Array(3...10))
        #expect(VeoModelFamily.from("veo-3.1-generate-001").durations(resolution: .r4k, usingReferenceImages: false) == [.s8])
    }
}
