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
    func testAppLaunchesToWelcomeScreen() {
        let app = XCUIApplication()
        app.launch()

        // Without Supabase configured the app starts signed out, so Welcome is
        // the expected first screen on a clean install.
        XCTAssertTrue(
            app.buttons["Sign in"].waitForExistence(timeout: 10),
            "Expected the welcome screen after launch"
        )
    }
}
