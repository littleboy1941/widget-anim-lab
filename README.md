# widget-anim-lab

Эксперименты с покадровой анимацией виджетов домашнего экрана iPhone **только на публичных API** WidgetKit/SwiftUI.

Приём: `Text(date, style: .timer)` система перерисовывает сама, а кастомный шрифт через лигатуры превращает цифры секунд в глифы. Мигающие шрифты-маски по очереди открывают кадры. Схема подробно описана в [`probe/fontgen.py`](probe/fontgen.py) и [`probe/Shared/TimerAnimation.swift`](probe/Shared/TimerAnimation.swift).

- `probe/fontgen.py` — генератор шрифтов (fontTools): кадры-глифы (цветной SVG) и мигающие маски.
- `probe/` — тестовое приложение с виджетами (XcodeGen), UI-тест, который ставит виджет на домашний экран симулятора, и разбор записи экрана (`analyze_video.swift`).
- `.github/workflows/font-probe.yml` — сборка Xcode 27, запуск на симуляторе iOS 27, IPA без подписи.

## Благодарности

Идея анимации через таймеры и шрифты — [Bryce Bostwick, WidgetAnimation](https://github.com/brycebostwick/WidgetAnimation) (MIT), видео «Apple's Widget Backdoor». Код здесь написан заново.

## Лицензия

MIT, см. [LICENSE](LICENSE).
