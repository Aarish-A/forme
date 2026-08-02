import XCTest

/// UI tests are slow, so keep this suite to the handful of end-to-end paths
/// that would be embarrassing to ship broken. Logic belongs in `FormeTests`.
///
/// `nonisolated` because `XCTestCase`'s initialisers and lifecycle hooks are
/// nonisolated, and the project defaults every type to `@MainActor`. Individual
/// tests opt back in with `@MainActor` where they touch `XCUIApplication`.
final nonisolated class FormeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesToWardrobe() {
        let app = XCUIApplication()
        app.launch()

        // Sign-in is disabled for now, so a clean install lands straight on
        // the wardrobe.
        XCTAssertTrue(
            app.navigationBars["Wardrobe"].waitForExistence(timeout: 10),
            "Expected the wardrobe screen after launch"
        )
    }
}
