import XCTest

final class FullFlowUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testUserFlowAndAddWidget() {
        let app = XCUIApplication()
        app.launch()

        guard require(app.buttons["flow-test-animations-menu"], in: app,
                      "нет меню тестовых анимаций", timeout: 20) else { return }
        assertNoAppError(in: app, at: "библиотека")
        app.buttons["flow-test-animations-menu"].tap()

        let fixture = app.buttons["flow-test-gif-ci_frames"]
        guard require(fixture, in: app, "нет ci_frames в меню", timeout: 10) else { return }
        fixture.tap()

        let openEditor = app.buttons["flow-open-editor"]
        guard require(openEditor, in: app, "не открылся анализ", timeout: 60) else { return }
        assertNoAppError(in: app, at: "анализ")
        openEditor.tap()

        let planTab = app.buttons["flow-editor-tab-План"]
        guard require(planTab, in: app, "не открылся редактор", timeout: 60) else { return }
        assertNoAppError(in: app, at: "редактор")
        planTab.tap()

        let allPlans = app.buttons["flow-all-plans"]
        guard require(allPlans, in: app, "нет списка планов", timeout: 15) else { return }
        allPlans.tap()

        let plan = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "flow-plan-8-12-")
        ).firstMatch
        var found = false
        for _ in 0..<40 {
            if plan.waitForExistence(timeout: 1) {
                found = true
                break
            }
            app.swipeUp()
        }
        guard found else {
            XCTFail(dump("нет плана 8 fps / 12 слотов", in: app))
            return
        }
        plan.tap()

        let editorDone = app.buttons["flow-editor-done"]
        guard require(editorDone, in: app, "нет кнопки Готово в редакторе", timeout: 15) else { return }
        assertNoAppError(in: app, at: "план выбран")
        guard editorDone.isEnabled else {
            XCTFail(dump("план не разрешил переход к проверке", in: app))
            return
        }
        editorDone.tap()

        let save = app.buttons["flow-save"]
        guard require(save, in: app, "не открылся экран проверки", timeout: 30) else { return }
        assertNoAppError(in: app, at: "проверка")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        guard XCTWaiter.wait(for: [enabled], timeout: 30) == .completed else {
            XCTFail(dump("кнопка Сохранить осталась недоступна", in: app))
            return
        }
        save.tap()

        guard require(app.staticTexts["flow-published"], in: app,
                      "не открылся экран Готово", timeout: 120) else { return }
        assertNoAppError(in: app, at: "Готово")

        XCUIDevice.shared.press(.home)
        guard require(springboard, in: springboard, "не открылся домашний экран", timeout: 15) else { return }
        sleep(2) // SpringBoard finishes its return animation before the long press.
        enterEditMode()
        guard openGallery() else { return }

        let search = springboard.searchFields.firstMatch
        guard require(search, in: springboard, "нет поиска в галерее", timeout: 15) else { return }
        search.tap()
        search.typeText("WidgetLab")
        let cell = springboard.cells["WidgetLab"]
        let button = springboard.buttons["WidgetLab"]
        let label = springboard.staticTexts["WidgetLab"]
        let result: XCUIElement?
        if cell.waitForExistence(timeout: 5) {
            result = cell
        } else if button.waitForExistence(timeout: 5) {
            result = button
        } else if label.waitForExistence(timeout: 5) {
            result = label
        } else {
            result = nil
        }
        guard let result else {
            XCTFail(dump("нет WidgetLab в результатах поиска", in: springboard))
            return
        }
        result.tap()

        let add = addWidgetButton()
        guard require(add, in: springboard, "нет кнопки Add Widget", timeout: 15) else { return }
        add.tap() // первая карточка галереи — маленький виджет

        let done = springboard.buttons["Done"]
        if done.waitForExistence(timeout: 5) {
            done.tap()
        } else {
            XCUIDevice.shared.press(.home)
        }
        print("== виджет добавлен\n" + springboard.debugDescription)
    }

    private func assertNoAppError(in app: XCUIApplication, at stage: String) {
        let error = app.descendants(matching: .any)
            .matching(identifier: "AppErrorView").firstMatch
        if error.exists { XCTFail(dump("AppErrorView на этапе: \(stage)", in: app)) }
    }

    private func require(_ element: XCUIElement, in app: XCUIApplication,
                         _ message: String, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail(dump(message, in: app))
            return false
        }
        return true
    }

    private func enterEditMode() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 2.0)
        let editHome = springboard.buttons["Edit Home Screen"]
        if editHome.waitForExistence(timeout: 3) { editHome.tap() }
    }

    private func addWidgetButton() -> XCUIElement {
        springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
    }

    private func openGallery() -> Bool {
        let add = addWidgetButton()
        if add.waitForExistence(timeout: 4) { add.tap(); return true }
        let edit = springboard.buttons["Edit"]
        if edit.waitForExistence(timeout: 6) {
            edit.tap()
            if add.waitForExistence(timeout: 8) { add.tap(); return true }
        }
        XCTFail(dump("не открылась галерея виджетов", in: springboard))
        return false
    }

    private func dump(_ message: String, in app: XCUIApplication) -> String {
        print("== \(message)\n" + app.debugDescription)
        return message
    }
}
