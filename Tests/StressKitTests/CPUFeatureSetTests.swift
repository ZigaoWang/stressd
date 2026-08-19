import Testing

@testable import StressKit

@Suite("CPU feature set")
struct CPUFeatureSetTests {

  @Test("hw.optional prefixes are stripped from flag names")
  func prefixStripping() {
    let features = CPUFeatureSet.make(fromOptionalSubtree: [
      ("hw.optional.arm.FEAT_SME2", 1),
      ("hw.optional.neon", 1),
      ("hw.optional.arm64", 1),
    ])

    #expect(features.has("FEAT_SME2"))
    #expect(features.has("neon"))
    #expect(features.flags["hw.optional.neon"] == nil)
  }

  @Test("Magnitudes are kept out of the flag list")
  func scalarsAreNotFlags() {
    // hw.optional.arm.caps is a 64-bit bitfield and sme_max_svl_b is a length.
    // Reporting either as a capability bit would be wrong, and sme_max_svl_b
    // is 0 on chips without SME so it would silently pass as a false flag.
    let features = CPUFeatureSet.make(fromOptionalSubtree: [
      ("hw.optional.arm.caps", 868_632_465_256_738_815),
      ("hw.optional.arm.sme_max_svl_b", 0),
      ("hw.optional.arm.FEAT_AES", 1),
    ])

    #expect(features.flags.keys.sorted() == ["FEAT_AES"])
    #expect(features.scalars["caps"] == 868_632_465_256_738_815)
    #expect(features.scalars["sme_max_svl_b"] == 0)
  }

  @Test("Present and absent flags are separated and sorted")
  func supportedAndUnsupported() {
    let features = CPUFeatureSet.make(fromOptionalSubtree: [
      ("hw.optional.arm.FEAT_BF16", 1),
      ("hw.optional.arm.FEAT_AES", 1),
      ("hw.optional.arm.FEAT_SME", 0),
      ("hw.optional.arm.FEAT_MTE", 0),
    ])

    #expect(features.supported == ["FEAT_AES", "FEAT_BF16"])
    #expect(features.unsupported == ["FEAT_MTE", "FEAT_SME"])
    #expect(features.supportedArchitecturalFeatures == ["FEAT_AES", "FEAT_BF16"])
  }

  @Test("Convenience accessors accept either spelling of a capability")
  func convenienceAccessors() {
    let neonOnly = CPUFeatureSet.make(fromOptionalSubtree: [("hw.optional.neon", 1)])
    #expect(neonOnly.hasNEON)

    let advSIMDOnly = CPUFeatureSet.make(fromOptionalSubtree: [("hw.optional.arm.AdvSIMD", 1)])
    #expect(advSIMDOnly.hasNEON)

    let empty = CPUFeatureSet.make(fromOptionalSubtree: [])
    #expect(!empty.hasNEON)
    #expect(!empty.hasSME)
  }
}
