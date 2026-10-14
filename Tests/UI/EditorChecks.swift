import XCTest

final class EditorChecks: XCTestCase {
    func testWorkoutAutomaticSyncSetting() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TreadmillFTMSProbe")
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let toggle = app.switches["自动同步运动到苹果健康"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate(); app.launch()
        app.tabBars.buttons["设置"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workout-auto-sync-settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
    }
    func testExternalFileImport() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TreadmillFTMSProbe")
        let valid = URL(fileURLWithPath: "/private/tmp/fitnessauto-external-ui.json")
        let invalid = URL(fileURLWithPath: "/private/tmp/fitnessauto-invalid-ui.json")
        app.open(valid)
        let confirm = app.buttons["confirmPlanImport"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["外部导入验证 1"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "import-preview"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["导入计划"].buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["外部导入验证 1"].exists)
        app.open(valid)
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["计划库"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["外部导入验证 1"].exists)
        app.terminate(); app.launch()
        app.tabBars.buttons["计划库"].tap()
        XCTAssertTrue(app.staticTexts["外部导入验证 1"].exists)
        app.open(invalid)
        XCTAssertTrue(app.staticTexts["无法导入计划"].waitForExistence(timeout: 10))
        let errorShot = XCTAttachment(screenshot: app.screenshot())
        errorShot.name = "import-error"; errorShot.lifetime = .keepAlways; add(errorShot)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["外部导入验证 1"].exists)
    }
    func testTrainingRedesign() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TreadmillFTMSProbe")
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        for state in ["idle", "running", "stopping", "stopUnconfirmed", "paused"] {
            app.launchArguments = ["--training-design", state]
            app.launch()
            let primary = app.buttons["trainingPrimaryAction"]
            XCTAssertTrue(primary.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["暂停自动调节"].exists)
            XCTAssertFalse(app.buttons["跳转到指定阶段"].exists)
            capture(state)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '个阶段'")).firstMatch.exists)
            if state == "idle" {
                XCTAssertTrue(primary.label.contains("开始训练"))
                primary.tap()
                XCTAssertTrue(primary.label.contains("停止训练"))
                primary.tap()
                XCTAssertTrue(primary.label.contains("正在停止"))
                XCTAssertFalse(primary.isEnabled)
            } else if state == "running" {
                XCTAssertTrue(app.staticTexts["trainingStageRemaining"].label.contains("00:01"))
                XCTAssertEqual(app.staticTexts["trainingElapsed"].label, "00:19")
                XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '计划进度'")).firstMatch.exists)
                XCTAssertEqual(app.staticTexts["trainingTarget"].label, "目标 5.0 km/h · 坡度 0%")
                app.buttons["trainingNextStage"].tap()
                XCTAssertTrue(app.staticTexts["trainingStageRemaining"].label.contains("00:40"))
                XCTAssertEqual(app.staticTexts["trainingElapsed"].label, "00:19")
                XCTAssertEqual(app.staticTexts["trainingTarget"].label, "目标 6.0 km/h · 坡度 2%")
                app.buttons["查看完整阶段表"].tap()
                let row = app.buttons["trainingStage-2"]
                if !row.isHittable { app.swipeUp() }
                row.tap()
                app.swipeDown()
                XCTAssertEqual(app.staticTexts["trainingTarget"].label, "目标 5.0 km/h · 坡度 6%")
                XCTAssertTrue(app.staticTexts["trainingStageRemaining"].label.contains("01:00"))
                XCTAssertEqual(app.staticTexts["trainingElapsed"].label, "00:19")
            } else if state == "stopping" {
                XCTAssertFalse(primary.isEnabled)
            } else if state == "stopUnconfirmed" {
                XCTAssertTrue(primary.label.contains("重试停止"))
            } else {
                XCTAssertTrue(app.buttons["trainingResume"].exists)
            }
            app.terminate()
        }
    }
    func testCenteredDelete() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TreadmillFTMSProbe")
        app.launch()
        app.tabBars.buttons["运动记录"].tap()
        let record = app.staticTexts["删除交互验证"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.swipeLeft()
        app.buttons["删除"].tap()
        let alert = app.alerts["删除这条运动记录？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "delete-alert"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS '删除交互验证'")).firstMatch.exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(record.exists)
        record.press(forDuration: 1.2)
        app.buttons["删除运动记录"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["删除"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: record)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["保留记录验证"].exists)
        app.terminate(); app.launch()
        app.tabBars.buttons["运动记录"].tap()
        XCTAssertFalse(record.exists)
        XCTAssertTrue(app.staticTexts["保留记录验证"].exists)
    }
}
