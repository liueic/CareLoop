import XCTest

final class CareLoopUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingSkipReachesJournalAndTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh-onboarding", "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8), "应看到 Onboarding 跳过按钮")
        Self.saveShot(app, name: "careloop-onboarding")
        for _ in 0..<6 {
            if app.tabBars.buttons["手帐"].exists { break }
            if skip.exists {
                skip.tap()
            } else if app.buttons["进入手帐"].exists {
                app.buttons["进入手帐"].tap()
            }
        }

        XCTAssertTrue(app.tabBars.buttons["手帐"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["journal.openCamera"].exists)
        Self.saveShot(app, name: "careloop-journal")

        app.tabBars.buttons["今日"].tap()
        XCTAssertTrue(app.staticTexts["今日状态"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["careloop.disclaimer"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "本应用不提供疾病诊断")).firstMatch.exists
        )
        Self.saveShot(app, name: "careloop-today")

        app.tabBars.buttons["用药"].tap()
        XCTAssertTrue(app.staticTexts["氨氯地平"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["二甲双胍"].exists)
        Self.saveShot(app, name: "careloop-meds")

        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 8))
        Self.saveShot(app, name: "careloop-settings")
    }

    @MainActor
    private static func saveShot(_ app: XCUIApplication, name: String) {
        let url = URL(fileURLWithPath: "/tmp/\(name).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    @MainActor
    func testSimulatorWatermarkCameraFallback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-skip-onboarding", "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        XCTAssertTrue(app.buttons["journal.openCamera"].waitForExistence(timeout: 8))
        app.buttons["journal.openCamera"].tap()
        let demo = app.buttons["camera.demoPhoto"]
        XCTAssertTrue(demo.waitForExistence(timeout: 8), "模拟器应提供演示照片入口")
        Self.saveShot(app, name: "careloop-camera-fallback")
        demo.tap()
        XCTAssertTrue(app.buttons["camera.saveDirect"].waitForExistence(timeout: 8))
        Self.saveShot(app, name: "careloop-camera-review")
        app.buttons["camera.saveDirect"].tap()
        XCTAssertTrue(app.buttons["journal.openCamera"].waitForExistence(timeout: 8))
    }
}
