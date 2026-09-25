// Ставит виджет «Probe B: images» на домашний экран симулятора, чтобы снять его на видео.
// Подписи кнопок SpringBoard разные в версиях iOS, поэтому на каждом шаге есть запасные
// варианты, а при неудаче в лог уходит дерево элементов SpringBoard.
import XCTest

final class AddWidgetUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testAddImagesWidget() throws {
        // Приложение открыть один раз, иначе виджета нет в галерее
        let app = XCUIApplication()
        app.launchArguments = ["images"]
        app.launch()
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(2)

        enterEditMode()
        openGallery()

        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), dump("нет поля поиска в галерее"))
        search.tap()
        search.typeText("FontProbe")
        sleep(2)

        guard let result = firstExisting([
            springboard.cells["FontProbe"],
            springboard.buttons["FontProbe"],
            springboard.staticTexts["FontProbe"],
        ], timeout: 10) else {
            XCTFail(dump("нет FontProbe в результатах поиска"))
            return
        }
        result.tap()
        sleep(2)
        print("== страница виджета\n" + springboard.debugDescription)

        // В iOS 27 подпись кнопки — ' Add Widget' (перед текстом значок)
        let add = addWidgetButton()
        XCTAssertTrue(add.waitForExistence(timeout: 10), dump("нет кнопки Add Widget"))
        add.tap()
        sleep(3)

        let done = springboard.buttons["Done"]
        if done.waitForExistence(timeout: 5) {
            done.tap()
        } else {
            XCUIDevice.shared.press(.home)
        }
        sleep(2)
        print("== итог\n" + springboard.debugDescription)
    }

    /// Опыт со свайпом (SWIPE_EXPERIMENTS): run.sh пишет видео, пока идёт этот тест.
    /// Переходы домашнего экрана: 3 раза страница влево и обратно, 3 раза «Настройки» → домой.
    /// Паузы по 3 с — чтобы между переходами был виден покой.
    func testSwipes() throws {
        XCUIDevice.shared.press(.home)
        sleep(3)
        for _ in 0..<3 {
            springboard.swipeLeft()
            sleep(3)
            springboard.swipeRight()
            sleep(3)
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        for _ in 0..<3 {
            settings.activate()
            sleep(3)
            XCUIDevice.shared.press(.home)
            sleep(3)
        }
    }

    /// Долгое нажатие на домашний экран. Если попали в иконку — пункт «Edit Home Screen».
    private func enterEditMode() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 2.0)
        sleep(1)
        let editHome = springboard.buttons["Edit Home Screen"]
        if editHome.waitForExistence(timeout: 2) {
            editHome.tap()
            sleep(1)
        }
    }

    /// Кнопка «Add Widget» в меню правки и в галерее; в iOS 27 в подписи перед текстом значок.
    private func addWidgetButton() -> XCUIElement {
        springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
    }

    /// В iOS 17 кнопка «+», в iOS 18+ «Edit» → «Add Widget».
    private func openGallery() {
        let add = addWidgetButton()
        if add.waitForExistence(timeout: 3) {
            add.tap()
            sleep(2)
            return
        }
        let edit = springboard.buttons["Edit"]
        if edit.waitForExistence(timeout: 5) {
            edit.tap()
            sleep(1)
            if add.waitForExistence(timeout: 5) {
                add.tap()
                sleep(2)
                return
            }
        }
        XCTFail(dump("не открылась галерея виджетов"))
    }

    private func firstExisting(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = elements.first(where: { $0.exists }) { return e }
            usleep(300_000)
        } while Date() < deadline
        return nil
    }

    private func dump(_ message: String) -> String {
        print("== \(message)\n" + springboard.debugDescription)
        return message
    }
}
