import XCTest
import Loopl

/// `Tests/LooplTests/Fixtures/models.json` is a VERBATIM copy of `App/Resources/models.json`:
/// `swift test` has no app bundle, so the catalog tests (`VisionContentTests.testCatalogVisionRows`,
/// `VisionTruthTests.testBundledLooplRowsArePublic…`, `PromptBuilderTests`) read the fixture while the
/// Xcode-hosted CI job reads the real resource. That is exactly how the two drifted apart: the
/// loopl-vl 2B and 4B rows reached the app in #150/#163 and never reached the fixture, so a pure
/// `swift test` counted 6 loopl rows against the app's 8 — and nobody saw it, because the hosted job
/// was green and the macOS job piped `swift test` into `tail` without `pipefail`.
///
/// This test closes the hole from the other side: the copy must still BE a copy. It reads both files
/// out of the source tree next to this file (`#filePath`), so it runs wherever the checkout is — and
/// skips, rather than lying, in a hosted run where only the bundle exists.
final class CatalogFixtureParityTests: XCTestCase {
    /// repo root, found from this file's path: Tests/LooplTests/<this file>
    private func repoRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/LooplTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("source tree not available (hosted test run) — the bundle resource is the catalog there")
        }
        return root
    }

    func testFixtureIsStillAVerbatimCopyOfTheAppCatalog() throws {
        let root = try repoRoot()
        let appURL = root.appendingPathComponent("App/Resources/models.json")
        let fixURL = root.appendingPathComponent("Tests/LooplTests/Fixtures/models.json")
        let app = try Data(contentsOf: appURL), fix = try Data(contentsOf: fixURL)
        guard app != fix else { return }

        // Not identical: say WHICH rows differ, so the fix is one copy command away.
        let a = try JSONDecoder().decode(Catalog.self, from: app), f = try JSONDecoder().decode(Catalog.self, from: fix)
        let aIDs = a.models.map(\.id), fIDs = f.models.map(\.id)
        let missing = aIDs.filter { !fIDs.contains($0) }, extra = fIDs.filter { !aIDs.contains($0) }
        XCTFail("""
            Tests/LooplTests/Fixtures/models.json has drifted from App/Resources/models.json \
            (\(aIDs.count) rows in the app, \(fIDs.count) in the fixture\
            \(missing.isEmpty ? "" : "; missing from the fixture: \(missing.joined(separator: ", "))")\
            \(extra.isEmpty ? "" : "; only in the fixture: \(extra.joined(separator: ", "))")).
            The fixture is a verbatim copy — run: cp App/Resources/models.json Tests/LooplTests/Fixtures/models.json
            """)
    }

    /// The loopl-row invariants, read from the APP file rather than from the copy — so a row added to
    /// `App/Resources/models.json` is checked by `swift test` even in the window before anyone syncs the
    /// fixture. Same rules as `VisionTruthTests`: the MLX/bf16 repos are public, only the GGUF builds are
    /// gated, and only the MLX runtime has an image path.
    func testAppCatalogLooplRowInvariants() throws {
        let root = try repoRoot()
        let c = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root.appendingPathComponent("App/Resources/models.json")))
        let loopl = c.models.filter { $0.repo.hasPrefix("cagataydev/loopl-") }
        XCTAssertFalse(loopl.isEmpty, "the app catalog ships the loopl rows")
        for row in loopl {
            XCTAssertEqual(row.gated, row.runtime == .gguf, "\(row.id): MLX repos are public, GGUF builds are private")
            XCTAssertEqual(row.supportsVision, row.runtime == .mlx, "\(row.id): only the MLX runtime has an image path")
        }
    }
}
