import XCTest

// MARK: - HomeShortsCountUITests
//
// Regression tests for task #91: Home Shorts row must show ≥ 6 cards after
// initial load, and new cards must appear when the row is scrolled.
//
// Launch args (per-test launch, matching RecommendedChipUITests pattern):
//   --uitesting                        standard test guard
//   --uitesting-inject-shorts-ids=...  injects 8 known video IDs so the test
//                                      does not depend on real network data or auth
//
// No --uitesting-reset-settings: preserves keychain auth so auth.isSignedIn
// is naturally true (or falls through to --uitesting-signed-in backup).

// 8 video IDs used as deterministic test fixtures.
private let kInjectedShortsIDs = [
    "dQw4w9WgXcQ", "jNQXAC9IVRw", "9bZkp7q19f0", "kffacxfA7G4",
    "hT_nvWreIhg", "OPf0YbXqDm0", "M7lc1UVf-VE", "YQHsXMglC9A"
]

final class HomeShortsCountUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",
            "--uitesting-signed-in",
            "--uitesting-inject-shorts-ids=\(kInjectedShortsIDs.joined(separator: ","))"
        ]
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Returns all `shorts.card.*` elements currently inside the `home.shortsRow` scroll view.
    private func shortsCards() -> [XCUIElement] {
        let row = app.scrollViews["home.shortsRow"]
        guard row.exists else { return [] }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        return row.otherElements.matching(predicate).allElementsBoundByIndex
            + row.buttons.matching(predicate).allElementsBoundByIndex
    }

    /// Waits until `home.shortsRow` exists and contains at least `minCount` cards.
    @discardableResult
    private func waitForShorts(minCount: Int, timeout: TimeInterval = 15) -> Int {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "home.shortsRow not found within \(timeout)s")

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let count = shortsCards().count
            if count >= minCount { return count }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return shortsCards().count
    }

    // MARK: - Tests

    /// After app launch the Shorts row must contain at least 3 cards (one full
    /// screen width on iPhone, threshold = 3 visible at once).
    func testShortsRowHasAtLeastThreeCardsOnLaunch() {
        let count = waitForShorts(minCount: 3)
        XCTAssertGreaterThanOrEqual(
            count, 3,
            "Shorts row should show ≥ 3 cards after load; got \(count)"
        )
    }

    /// After app load the Shorts row must contain at least 6 cards so that
    /// the user has two full screens of content ready without waiting.
    func testShortsRowHasAtLeastSixCardsAfterLoad() {
        let count = waitForShorts(minCount: 6)
        XCTAssertGreaterThanOrEqual(
            count, 6,
            "Shorts row should show ≥ 6 cards (2 screens × 3 cards/screen); got \(count). " +
            "Injected \(kInjectedShortsIDs.count) IDs — check --uitesting-inject-shorts-ids handling."
        )
    }

    /// Scrolling the Shorts row to the right must reveal cards not visible at
    /// the initial position — i.e. the row is not limited to the initially-visible cards.
    func testScrollingShortsRowRevealsMoreCards() {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "home.shortsRow not found")

        // Wait for at least one card to appear before recording IDs.
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline && shortsCards().isEmpty {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Collect the IDs that are visible before scrolling.
        let beforeIDs = Set(shortsCards().map { $0.identifier })
        XCTAssertFalse(beforeIDs.isEmpty, "Shorts row must contain cards before scrolling")

        // Swipe left three times to scroll through the row.
        for _ in 0..<3 {
            row.swipeLeft(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.4)
        }

        // After scrolling there should be at least one card that wasn't in the
        // initial view (proves the row has more than the initially-visible cards).
        let afterIDs = Set(shortsCards().map { $0.identifier })
        let newIDs = afterIDs.subtracting(beforeIDs)
        XCTAssertFalse(
            newIDs.isEmpty,
            "Scrolling the Shorts row should reveal new cards; none appeared. " +
            "Before IDs: \(beforeIDs), After IDs: \(afterIDs)"
        )
    }
}
