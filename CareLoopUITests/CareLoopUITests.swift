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
        XCTAssertTrue(app.buttons["饮食问一问"].waitForExistence(timeout: 8), "今日页应显示饮食入口")
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

    /// 饱饱对话：工具调用进度可见 + 流式回复到达（全程 Mock，无网络）。
    @MainActor
    func testDietChatStreamingWithToolProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-skip-onboarding", "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["CARELOOP_FORCE_CLOUD_AGENT"] = "1"
        app.launch()

        // 跳过引导后默认落在手帐页，先切到今日。
        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 8))
        app.tabBars.buttons["今日"].tap()
        let askButton = app.buttons["饮食问一问"]
        XCTAssertTrue(askButton.waitForExistence(timeout: 10), "今日页应显示饮食问一问入口")
        askButton.tap()

        // iOS 26 的竖排 TextField 底层可能是 UITextView，按任意类型查标识符最稳。
        let input = app.descendants(matching: .any)["careloop.diet.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8), "应进入饱饱对话页")
        Self.saveShot(app, name: "careloop-diet-chat")

        // 含"今晚"触发 Mock 的工具调用轮。
        input.tap()
        input.typeText("今晚吃什么好")
        app.buttons["careloop.diet.send"].tap()

        // 工具进度 chip 出现（Mock 带 250ms 模拟延迟，留足观察窗口）。
        let toolChip = app.staticTexts["筛选安全食谱"]
        XCTAssertTrue(toolChip.waitForExistence(timeout: 20), "应显示工具调用进度")
        Self.saveShot(app, name: "careloop-diet-tools")

        // 最终回复到达（Mock 的饮食回复文本）。
        let finalReply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "清淡少盐")
        ).firstMatch
        XCTAssertTrue(finalReply.waitForExistence(timeout: 30), "应收到流式完成的最终回复")
        Self.saveShot(app, name: "careloop-diet-reply")

        // 回到空闲态：发送按钮重新可用。
        XCTAssertTrue(app.buttons["careloop.diet.send"].waitForExistence(timeout: 5))
    }
}
