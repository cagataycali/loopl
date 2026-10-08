import XCTest
@testable import Loopl
import LooplUI

/// IMPROVE-4: words small models copy and words people wait on.
final class PlainWordsTests: XCTestCase {
    /// Measured on Qwen3 0.6B: "what time is it right now?" → `current_time(timezone: "Europe/Istanbul")` — the example city in
    /// the description went straight into the call. No city example in the description; the device default is the loud part.
    func testCurrentTimeDescriptionCarriesNoExampleCity() {
        let d = CurrentTimeTool().description
        XCTAssertFalse(d.contains("Istanbul"), d)
        XCTAssertFalse(d.contains("Los_Angeles"), d)
        XCTAssertTrue(d.lowercased().contains("no arguments"), "the default call is spelled out: \(d)")
        XCTAssertTrue(d.lowercased().contains("another place"), "when to pass a zone is spelled out: \(d)")
    }

    /// With no timezone the tool answers in the device zone (the default the description promises).
    func testCurrentTimeDefaultsToDeviceZone() async throws {
        let out = try await CurrentTimeTool().call([:])
        XCTAssertTrue(out.contains(TimeZone.current.identifier) || out.contains(TimeZone.current.abbreviation() ?? "§"), out)
    }

    /// The pending row says what is happening once the wait is long (IMPROVE-4 #12).
    func testPendingRowCaptionGrowsWithTheWait() {
        XCTAssertEqual(PendingRow.caption(after: 0), "…")
        XCTAssertEqual(PendingRow.caption(after: 3.9), "…")
        XCTAssertEqual(PendingRow.caption(after: 4), "Reading your message and the tools…")
        XCTAssertEqual(PendingRow.caption(after: 20), "Still reading — a big prompt takes longer on this device.")
    }

    /// The three load-failure messages. Each is read by someone whose model will not start, so each must say
    /// what is wrong and name an action **that exists** — and they must not be interchangeable, because the
    /// three states are not (IMPROVE-9).
    func testLoadFailureMessagesMatchTheirState() {
        let internet = TokenizerFiles.needsInternetMessage(for: "loopl 2B")
        let fetch = TokenizerFiles.fetchFailedMessage(for: "loopl 2B")
        let stuck = TokenizerFiles.cannotBeFixedMessage(for: "loopl 2B")

        for m in [internet, fetch, stuck] {
            XCTAssertTrue(m.hasPrefix("loopl 2B"), m)
            // The packager's vocabulary.
            for word in ["tokenizer", "weights", "a few KB", "repo itself"] {
                XCTAssertFalse(m.lowercased().contains(word.lowercased()), "\(word) is not the reader's word: \(m)")
            }
            // THE BUG THIS REPLACED: there is no Repair button in loopl, so no message may send anyone to one.
            XCTAssertFalse(m.lowercased().contains("repair"), "names a control that does not exist: \(m)")
        }

        // Offline is the one state where waiting helps, so it says so and points at the real button.
        XCTAssertTrue(internet.contains("needs the internet"), internet)
        XCTAssertTrue(internet.contains("Try again"), "names the button that is really there: \(internet)")
        XCTAssertTrue(internet.contains("kilobytes"), "nobody should fear a second big download: \(internet)")
        XCTAssertTrue(internet.lowercased().contains("stays on your device"), internet)

        // A failed fetch is worth retrying.
        XCTAssertTrue(fetch.contains("Try again"), fetch)

        // The dead end must NOT offer a retry — and must say whose fault it is not.
        XCTAssertFalse(stuck.contains("Try again"), "a dead end must not dangle a retry: \(stuck)")
        XCTAssertTrue(stuck.contains("nothing here will fix it"), stuck)
        XCTAssertTrue(stuck.contains("Try another model"), "gives them the move that is theirs: \(stuck)")
    }

    /// **No message may name a control the app does not have.** `repairMessage` said "tap Repair" at all three
    /// failure sites and loopl has never had a Repair button — the repair is automatic and the only control in
    /// the failed state is Try again. This is the generalisable half of that bug: if the string says *tap X*,
    /// some view had better declare X.
    func testNoMessageSendsTheReaderToAButtonThatDoesNotExist() throws {
        let root = try repoRoot()
        let views = try source(in: root, "App/Sources")
        let all = views + (try source(in: root, "Sources"))
        // IMPROVE-9 handoff item: the first version of this guard only caught the imperative "tap X", so
        // "use the Repair button" or "press Repair" would have walked straight past it. All three forms now.
        let forms = ["tap repair", "tap the repair", "use the repair", "press repair", "press the repair"]
        for (name, text) in all {
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let l = line.lowercased()
                guard forms.contains(where: { l.contains($0) }) else { continue }
                // Only legitimate if a view really declares one.
                let declared = views.contains { $0.1.contains("Button(\"Repair\")") || $0.1.contains("\"Repair\")") }
                XCTAssertTrue(declared, "\(name) points at a Repair button that no view declares: \(line)")
            }
        }
    }

    /// **The retired sentences, pinned so they cannot come back.** Each one was measured wrong in IMPROVE-9 and
    /// is quoted here verbatim; the scan reads the source tree next to this file (`#filePath`), the same way
    /// `CatalogFixtureParityTests` does, so it runs wherever the checkout is.
    ///
    /// Pinning *retired phrases* rather than banning *words* is deliberate: a word ban on "repo" or "Metal"
    /// would fire on comments, identifiers and the places those words are genuinely correct (the Format picker
    /// still says MLX and GGUF, because someone choosing between them needs the names). This has no false
    /// positives and still stops the exact regression.
    func testRetiredPackagerSentencesDoNotComeBack() throws {
        let root = try repoRoot()
        let retired = [
            "tokenizer files are out of date",        // asked the reader to know what a tokenizer is
            "tap Repair",                             // named a control loopl has never had
            "the repo itself needs fixing",           // asked them to fix a repository they do not own
            "instruct checkpoints only",              // jargon, and untrue: the filter is isTextGeneration
            "gated repos are hidden",
            "mlx-community conversions",
            "Pick the quant in the details",
            // this PR
            "Weights, tokenizer and configs are downloaded",
            "No MLX or GGUF repos under",
            "Private repos in your account",
            "Text(\"GGUF: ",                          // a raw error labelled with a file format
        ]
        var offenders: [String] = []
        for dir in ["App/Sources", "Sources"] {
            for (name, text) in try source(in: root, dir) {
                // Skip the lines that quote a retired sentence in order to explain why it was retired.
                let live = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                for phrase in retired where live.contains(phrase) {
                    offenders.append("\(name): “\(phrase)”")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "retired copy is back: \(offenders.joined(separator: " · "))")
    }

    /// **A view may not hardcode which device it is running on.** `LooplDesign.deviceName` resolves it
    /// ("iPhone" / "iPad" / "Mac"), and `ModelsView` was already asking it in FIVE places while hardcoding
    /// "iPhone" in two others — one of them a visible `Button("Move to this iPhone")` that an iPad owner
    /// taps, plus a VoiceOver hint. Same question, two answers, one file.
    ///
    /// Scoped to the phrases that are always a claim about the hardware, so the things that are correct all
    /// pass: `systemImage: "iphone"` (an SF Symbol name), accessibility identifiers, and the generic
    /// "this device" — which is right everywhere and is what a tool row says now (#212).
    func testNoViewHardcodesTheDeviceItRunsOn() throws {
        let root = try repoRoot()
        var offenders: [String] = []
        for (name, text) in try source(in: root, "App/Sources/Views") {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for phrase in ["this iPhone", "your iPhone", "this iPad", "your iPad"] where line.contains(phrase) {
                    offenders.append("\(name):\(i + 1) “\(phrase)”")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a view cannot know which device this is — use LooplDesign.deviceName: \(offenders.joined(separator: " · "))")
    }

    private func repoRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/LooplTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Every `.swift` file under `dir`, as (filename, contents).
    private func source(in root: URL, _ dir: String) throws -> [(String, String)] {
        let base = root.appendingPathComponent(dir)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) { out.append((url.lastPathComponent, text)) }
        }
        return out
    }
}
