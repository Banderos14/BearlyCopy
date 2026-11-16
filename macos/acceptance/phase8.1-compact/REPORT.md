# Phase 8.1 — Compact contextual help

Целевая доработка существующей системы подсказок. HEAD: `330f937c0d91e7bb1ba0f0daba4969fedd1de0da`, ветка `claude/loving-mccarthy-ossw3q`. Новых коммитов нет. Начальные незакоммиченные изменения сохранены; их снимок — `starting-working-tree.patch` и `starting-Phase81Tests.swift.txt`. AppModel.swift и NotchControllerTests.swift не изменились относительно начала этой доработки.

## Причина и исправление

Прежний резерв 28 pt складывался с обычным нижним padding: под Footer оставалось 38 pt на минимальном Details и 46 pt на остальных проверенных размерах даже без подсказки.

Теперь SwiftUI Layout измеряет естественную ширину текста и ограничивает её доступной шириной островка. Текст занимает одну строку либо максимум две; избыточный текст сокращается. Высота измеряется `onGeometryChange`. Обычный нижний отступ — 20 pt, без отдельного резерва: в него помещается короткая подсказка. Для второй строки отступ равен измеренной высоте текста + 6 pt снизу + 1 pt до содержимого. При скрытии измеренная высота сбрасывается в ноль.

Высота панели на время подсказки сохраняется. Details перераспределяет существующий HeightBudget. Quick Peek отдаёт второй строке часть трёх промежутков между блоками, сохраняя высоту Task, Answer и кнопок. Первый проверочный прогон выявил пересечение длинной подсказки с Footer Quick Peek; это исправлено и проверено повторно.

Первое появление: 180 ms. Переключение между кнопками: сразу; 120 ms перед скрытием позволяют пройти зазор. Нажатие, закрытие и исчезновение элемента скрывают подсказку сразу. Изменение высоты — ease-out 140 ms; Reduce Motion отключает эту анимацию. Один экземпляр текста сохраняет identity при смене владельца; clip и inset меняются совместно. Фокус клавиатуры и accessibility hint используют тот же текст. Отдельных AppKit `.help` в Notch нет.

## Измерения

Значения `height` — бюджет содержимого; полная высота Details включает верхнюю полосу 32 pt. Измерения получены на одной тестовой модели до и после изменения; скрытая и короткая подсказки сохраняют одинаковую геометрию Footer. Освобождённое место Details распределяется между карточками, а Quick Peek становится ниже.

| Поверхность | Бюджет, pt | Панель до → после, pt | Под Footer до → после, pt | Освобождено, pt | Answer до → после, pt |
| --- | --- | --- | --- | --- | --- |
| details | 268 | 300 → 300 | 38 → 20 | 18 | 106 → 124 |
| peek | 268 | 201 → 175 | 46 → 20 | 26 | 15 → 15 |
| details | 341 | 373 → 373 | 46 → 20 | 26 | 138 → 140 |
| peek | 341 | 201 → 175 | 46 → 20 | 26 | 15 → 15 |
| details | 448 | 480 → 480 | 46 → 20 | 26 | 182.56 → 205 |
| peek | 448 | 201 → 175 | 46 → 20 | 26 | 15 → 15 |

Исходные измерения: `before.json`, `after.json`. Рендеры `details-*` и `peek-*`: hidden, short, two-lines, transfer-help для бюджетов 268/341/448. Это offscreen-рендеры NSHostingView, не пользовательская проверка живого островка.

## Тексты

Сокращены Copy Answer, Copy with Context, Full Report, Full Task, Preview, History, Clipboard, Settings, Evidence, работа с вложениями, импортом, командами и передачей файлов. Например: `Copy the original answer`, `Copy the answer with project context`, `Preview exactly what will be copied`, `Read the complete answer`, `Customize Prompt Relay`. Убраны служебные идентификаторы сессии, пути и provenance из hover. Происхождение и исходный путь файла доступны в подробной карточке вложения. Снята общая подсказка строки предложения файла, конкурировавшая с подсказкой кнопки Add.

## Проверки и реальные коды завершения

Все Swift-запуски использовали `swift test --disable-sandbox --cache-path /tmp/prompt-relay-p81-cache --filter …`. Полный stdout/stderr перенаправлялся в файл, сразу после команды сохранялся `$?` в соответствующий `.exit`; pipelines не использовались. Тесты работают с именованным тестовым pasteboard и временными данными, не с системным clipboard.

- `baseline.log`, exit 0: 1 Swift Testing, измерения до изменения.
- `targeted.log`, exit 1: первый прогон выявил пересечение двухстрочной подсказки Quick Peek и устаревшие ожидания многострочных tooltip. Причины исправлены. Два opt-in теста Phase 8 (`testRenderPhase8States`, `testRenderRelayPointerSheet`) пропущены: `PROMPT_RELAY_VISUALS` не задан.
- `refined.log`, exit 0: 3 XCTest и 3 Swift Testing. CompactHelpTests, Phase81Tests.helpNeverCoversContent, Phase8Tests.testWrappedTip…, TooltipWidthTests, Phase6PolishTests.testTooltips… .
- `final-layout.log`, exit 1: все 9 XCTest и оба геометрических Swift Testing прошли, включая новый длинный текст над незавершённой передачей файлов; тест rapidSwitchingAndDismissal выявил нестабильное ожидание таймера при занятости MainActor другим offscreen-тестом. Ожидание в тесте исправлено на ограниченное ожидание состояния; скорость приложения не менялась.
- `scheduling.log`, exit 0: оба Swift Testing прошли, включая исправленный rapidSwitchingAndDismissal параллельно с Phase81Tests.helpNeverCoversContent (62.368 s).

Итог по последним результатам целевых наборов: 12 XCTest и 3 Swift Testing прошли. Это число уникальных тестов из refined/final-layout/scheduling; повторные запуски не суммируются. Все ранее упавшие проверки успешно перепроверены. Пропущенные opt-in тесты не считаются пройденными.
- `xcode-build.log`: BuildProject — successful, 7.238 s, ошибок нет. Есть предупреждение об отсутствии AppIntents.framework при извлечении metadata.
- `diff-check.log`, exit 0: `git diff --check`.

Геометрические тесты проверяют короткую, двухстрочную и скрытую подсказки, возврат от длинной к короткой, отсутствие роста панели и пересечений с Task, Answer, Evidence, Attachments и Footer. Проверены Details и Quick Peek на всех трёх размерах, обычный режим и Reduce Motion, незавершённая передача файлов, остальные интерактивные anchors. Дополнительно прошли существующие проверки границ островка, изображений, самого широкого Footer и предпросмотра вложений. Полного прогона репозитория не было.

## Что проверить владельцу

1. На живом островке быстро провести мышь между Copy Answer, Copy with Context, Full Report, Preview, Settings, Clipboard и History, затем выйти за пределы панели. Проверить читаемость и отсутствие мерцания; короткие подсказки не должны двигать карточки.
2. Повторить в Quick Peek и с незавершённой передачей файлов, затем на минимальном размере Details.
3. Включить клавиатурную навигацию и пройти кнопки Tab/Shift-Tab; проверить подсказки и VoiceOver hints.
4. Повторить с системным Reduce Motion. Оценить плавность на реальном экране; offscreen-геометрия не заменяет такую оценку.

Реальная мышь, аппаратная клавиатурная навигация и VoiceOver в этой доработке не проверялись. Вставка в ChatGPT не выполнялась. Захват Claude Code, настройки, история, системный clipboard и внешность Relay не менялись.

## Git status и файлы

Текущая доработка: `Notch/{IslandTooltips,IslandViews,NotchController,NotchViews,DetailsViews,ClipboardViews,EvidenceViews,PreviewViews}.swift`, `UI/Labels.swift`; тесты `CompactHelpTests.swift`, `Phase81Tests.swift`, `Phase8Tests.swift`, `Phase71Tests.swift`, `Phase6PolishTests.swift`; артефакты в этой папке. AppModel.swift и NotchControllerTests.swift содержат только ранее существовавшие изменения. Предыдущая папка acceptance/phase8.1 сохранена.

```text
 M Sources/PromptRelayKit/Notch/ClipboardViews.swift
 M Sources/PromptRelayKit/Notch/DetailsViews.swift
 M Sources/PromptRelayKit/Notch/EvidenceViews.swift
 M Sources/PromptRelayKit/Notch/IslandTooltips.swift
 M Sources/PromptRelayKit/Notch/IslandViews.swift
 M Sources/PromptRelayKit/Notch/NotchController.swift
 M Sources/PromptRelayKit/Notch/NotchViews.swift
 M Sources/PromptRelayKit/Notch/PreviewViews.swift
 M Sources/PromptRelayKit/Presentation/AppModel.swift
 M Sources/PromptRelayKit/UI/Labels.swift
 M Tests/PromptRelayKitTests/NotchControllerTests.swift
 M Tests/PromptRelayKitTests/Phase6PolishTests.swift
 M Tests/PromptRelayKitTests/Phase71Tests.swift
 M Tests/PromptRelayKitTests/Phase8Tests.swift
?? Tests/PromptRelayKitTests/CompactHelpTests.swift
?? Tests/PromptRelayKitTests/Phase81Tests.swift
?? acceptance/
```

Push, merge и destructive Git-команды не выполнялись.
