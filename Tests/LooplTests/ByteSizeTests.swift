import Foundation
import Testing
@testable import Loopl

/// `ByteCountFormatter` says "Zero KB" for an empty device, which reads like a
/// broken gauge. These pin the honest labels instead.
@Suite struct ByteSizeTests {
    @Test func zeroIsNoneNotZeroKB() {
        #expect(ByteSize.label(0) == "None")
        #expect(ByteSize.label(Int64(0)) == "None")
        // the thing we are actually guarding against:
        #expect(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file).contains("Zero"))
        #expect(!ByteSize.label(0).contains("Zero"))
    }

    @Test func negativeIsAlsoNone() {
        #expect(ByteSize.label(-1) == "None")
        #expect(ByteSize.label(Int64.min) == "None")
    }

    @Test func customZeroWord() {
        #expect(ByteSize.label(0, zero: "size unknown") == "size unknown")
        #expect(ByteSize.label(0, zero: "—") == "—")
    }

    @Test func realSizesKeepTheSystemFormatter() {
        #expect(ByteSize.label(968_080_210) == ByteCountFormatter.string(fromByteCount: 968_080_210, countStyle: .file))
        #expect(ByteSize.label(968_080_210).contains("MB"))
        #expect(ByteSize.label(4_000_000_000).contains("GB"))
        #expect(ByteSize.label(1, zero: "None") != "None")
    }

    @Test func modelSpecSizeLabelNeverSaysZeroKB() throws {
        let json = """
        {"id":"x","name":"X","repo":"","runtime":"appleFM","family":"generic","params_b":3,
         "size_bytes":0,"ctx_nominal":4096,"ctx_usable_8gb":4096,"min_ram_gb":0,"gated":false}
        """
        let spec = try JSONDecoder().decode(ModelSpec.self, from: Data(json.utf8))
        #expect(spec.sizeLabel == "size unknown")
        #expect(!spec.isDownloadable)          // Apple Intelligence: no download at all
    }
}
