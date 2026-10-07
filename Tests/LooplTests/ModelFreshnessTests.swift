import XCTest
@testable import Loopl

/// The rule that decides whether to tell someone their 1.75 GB copy is out of date.
final class ModelFreshnessTests: XCTestCase {
    private let day = TimeInterval(86_400)

    func testSaysNothingWhenItCannotKnow() {
        let mine = InstalledVersion(sha: "47d27b44aa", at: Date())
        XCTAssertEqual(ModelFreshness.verdict(installed: nil, remote: "47d27b44aa"), .unknown, "no record of this copy")
        XCTAssertEqual(ModelFreshness.verdict(installed: InstalledVersion(sha: nil, at: Date()), remote: "47d27b44aa"), .unknown,
                       "downloaded before loopl recorded revisions — never guessed at")
        XCTAssertEqual(ModelFreshness.verdict(installed: mine, remote: nil), .unknown, "the Hub has not been asked")
        XCTAssertEqual(ModelFreshness.verdict(installed: mine, remote: ""), .unknown, "an empty answer is not an answer")
        XCTAssertNil(ModelFreshness.line(installed: nil, remote: nil), "nothing known, nothing said")
    }

    func testCurrentWhenTheShasMatch() {
        let mine = InstalledVersion(sha: "3269d409ff", at: Date())
        XCTAssertEqual(ModelFreshness.verdict(installed: mine, remote: "3269d409ff"), .current)
        XCTAssertNil(ModelFreshness.line(installed: mine, remote: "3269d409ff"), "a current copy is never mentioned")
    }

    func testNewerNamesTheDayTheCopyArrived() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let today = InstalledVersion(sha: "v11", at: now.addingTimeInterval(-3_600))
        XCTAssertEqual(ModelFreshness.verdict(installed: today, remote: "v12"), .newer(installed: today))
        XCTAssertEqual(ModelFreshness.line(installed: today, remote: "v12", now: now),
                       "Hugging Face has a newer version. Your copy arrived today.")
        let yesterday = InstalledVersion(sha: "v11", at: now.addingTimeInterval(-day))
        XCTAssertEqual(ModelFreshness.line(installed: yesterday, remote: "v12", now: now),
                       "Hugging Face has a newer version. Your copy arrived yesterday.")
        let older = InstalledVersion(sha: "v11", at: now.addingTimeInterval(-9 * day))
        let line = ModelFreshness.line(installed: older, remote: "v12", now: now) ?? ""
        XCTAssertTrue(line.contains("arrived on "), line)
        XCTAssertFalse(line.contains("sha") || line.contains("commit") || line.contains("revision"), "no Hub vocabulary in the row: " + line)
    }

    func testShortShaIsWhatAModelCardShows() {
        XCTAssertEqual(InstalledVersion(sha: "47d27b4415f8f9e35d352fdfecc02f551103366a", at: Date()).shortSha, "47d27b44")
        XCTAssertNil(InstalledVersion(sha: nil, at: Date()).shortSha)
    }
}
