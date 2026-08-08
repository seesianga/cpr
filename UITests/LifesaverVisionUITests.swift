import XCTest

final class LifesaverVisionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    @MainActor
    func testM9RendersLockedAndHasNoLessonPlayerRoute() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-authenticated-learner",
            "--ui-test-skip-onboarding"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        let courses = app.descendants(matching: .any)["Courses"]
        XCTAssertTrue(courses.waitForExistence(timeout: 10))
        courses.tap()

        let lockedM9 = app.descendants(matching: .any)["module-card-M9"]
        for _ in 0..<12 where !lockedM9.exists {
            app.swipeUp()
        }

        XCTAssertTrue(
            lockedM9.waitForExistence(timeout: 5),
            "M9 must remain visibly rendered with its access explanation"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["module-open-M9"].exists,
            "A non-presentable M9 card must not be wrapped in a lesson-player NavigationLink"
        )
        XCTAssertTrue(
            lockedM9.label.localizedCaseInsensitiveContains("instructor approval"),
            "The locked card must explain the separate instructor-approval requirement"
        )
    }
}
