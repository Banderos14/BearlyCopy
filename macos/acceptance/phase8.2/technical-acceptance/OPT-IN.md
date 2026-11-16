# 16 opt-in тестов

Все перечисленные тесты отключены в полном автоматическом прогоне; пропуск не является успешным прохождением.

| Тест | Рекомендация |
| --- | --- |
| `IslandLayoutTests.testWriteVisualExamples` | Целесообразен один актуальный набор рендеров перед коммитом; специальные Phase82 рендеры уже сохранены. Остальные дубли необязательны. |
| `NotchControllerTests.testTheRealOpenPanelGetsTheScreenAndTheIslandComesBack` | Рекомендуется перед окончательной UI-приёмкой, интерактивно с владельцем. |
| `PasteInteropKit.testPutTestContentOnTheGeneralPasteboard` | Не запускать автоматически: меняет системный clipboard. Только отдельная ручная проверка владельцем. |
| `Phase6PolishTests.testWriteThemeComparison` | Необязательно перед коммитом: дополнительный рендер прежних тем/поз, которые не менялись. |
| `Phase6Tests.testRenderRealHistory` | Необязательно перед коммитом; использует реальную историю. |
| `Phase6Tests.testWritePhase6Visuals` | Необязательно перед коммитом: дополнительный рендер прежних тем/поз, которые не менялись. |
| `Phase6VisualTests.testWriteWarmCocoaVisuals` | Необязательно перед коммитом: дополнительный рендер прежних тем/поз, которые не менялись. |
| `Phase8Tests.testRenderPhase8States` | Целесообразен один актуальный набор рендеров перед коммитом; специальные Phase82 рендеры уже сохранены. Остальные дубли необязательны. |
| `Phase8Tests.testRenderRelayPointerSheet` | Необязательно перед коммитом: дополнительный рендер прежних тем/поз, которые не менялись. |
| `RealHandoffE2ETests.testRealTurnSuggestionsCopyAndFileHandoff` | Полезно перед финальной приёмкой, нужны выбранная реальная сессия и эталонные данные. |
| `RealSessionAuditTests.testRealCapturedReportSurvivesCopyReviewPackAndReader` | Полезно перед финальной приёмкой, нужны выбранная реальная сессия и эталонные данные. |
| `RelayLayerPoseRenderTests.testRenderPosesThroughLayers` | Необязательно перед коммитом: дополнительный рендер прежних тем/поз, которые не менялись. |
| `RelayPerformanceTests.testCPUWhileThePointerIsStillAndMoving` | Полезно перед окончательной UI-приёмкой для оценки CPU; не заменяет живые движения мыши. |
| `RelayPoseRenderTests.testRenderPoses` | Необязательно перед коммитом: дополнительный рендер прежних тем/поз, которые не менялись. |
| `SnapshotTests.testRenderSurfaces` | Целесообразен один актуальный набор рендеров перед коммитом; специальные Phase82 рендеры уже сохранены. Остальные дубли необязательны. |
| `SurfaceAuditRenderTests.testRenderSurfacesForAudit` | Целесообразен один актуальный набор рендеров перед коммитом; специальные Phase82 рендеры уже сохранены. Остальные дубли необязательны. |
