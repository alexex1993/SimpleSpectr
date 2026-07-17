# Min/max dB + reference level (режимы Auto / Manual)

## Контекст и решения

- **Mode switch (Auto + Manual):**
  - **Auto** — сохраняет текущую семантику `maxDB = peak файла`, но делает *ширину* окна (захардкоженный `90`) пользовательской. Один ползунок.
  - **Manual** — абсолютные `min`/`max` dBFS, окно закреплено (независимо от пика файла). Два ползунка. Лучше для сравнения файлов с разным уровнем.
- **Reference level = отдельного ползунка нет.** В Manual потолок (ceiling) сам служит точкой отсчёта.
- **Дешёвый путь подтверждён:** `SpectrogramResult.magnitudes` — сырые dBFS (`vDSP_vdbcon` с `ref = 1.0`), а `minDB`/`maxDB` применяются только в `renderImage`. Значит смена диапазона — это `rerenderFromCache`, без ре-декода. Точно как palette/scale.
- **Default = текущее поведение** (`.auto`, ширина 90), чтобы существующие пользователи не увидели разницы.

## Ключевая проектная идея

Добавить compact Sendable-struct `DynamicRangeSettings` с методом `resolve(peak:) -> (minDB, maxDB)`, чтобы разрешение окна было в одном месте и для batch (`generate`), и для rerender, и для live. В `SpectrogramResult` добавить поле `peakDB` (frozen at STFT time), чтобы Auto-rerender не сканировал весь грид заново.

## Изменения по файлам

### 1. `RenderPreferences.swift` — новые настройки + resolver
- Добавить nested `enum Mode: String { case auto, manual }` (Sendable).
- Добавить persisted-поля (по образцу `frequencyScale`): `dynamicRangeMode`, `autoRangeWidth: Double` (default 90, clamp 6…180), `manualMinDB: Double` (default −90), `manualMaxDB: Double` (default 0). `Keys`, `@Published` + `didSet`, `init()` — идентично существующим.
- Добавить computed `var dynamicRangeSettings: DynamicRangeSettings` (snapshot для Task.detached).
- Pure-функция resolver живёт либо здесь (static), либо в новом мелком типе; сигнатура: `resolve(mode, autoWidth, manualMin, manualMax, peak: Float) -> (min: Float, max: Float)`.
- Обновить doc-комментарий класса (analysis vs display split): пометить новые поля как display-only.

### 2. `SpectrogramEngine.swift`
- **`SpectrogramResult`**: добавить `let peakDB: Double` (для Auto-rerender без ре-скана); пробросить во все конструкторы.
- **`rerendered(...)`** (строки 65–82): добавить опциональные `minDB:`/`maxDB:` (по умолчанию `nil` → сохраняет текущее) — чтобы cached-result отражал новое окно для slice/export.
- **`generate(...)`** (строки 114–120, 247–250): заменить захардкоженный `dynamicRange: Float = 90` + `peak-90` на вызов resolver с prefs. Принимает новые параметры (`mode`/`autoWidth`/`manualMin`/`manualMax`) — snapshot'ится в `SpectrogramModel.load` до ухода с MainActor, как `fftSize`/`overlap`/… Заполнить `peakDB: Double(globalMax)` в возвращаемом `SpectrogramResult`.
- **`renderImage`** — без изменений (уже принимает `minDB`/`maxDB`).

### 3. `SpectrogramModel.swift`
- **`load`** (строки 98–117): snapshot'нуть новые prefs и передать в `generate`.
- **`rerenderFromCache`** (строки 147–163): вычислить `let (minDB, maxDB) = prefs.dynamicRangeSettings.resolve(peak: Float(result.peakDB))` и передать в `renderImage` вместо `Float(result.minDB)`/`Float(result.maxDB)`. Прокинуть `minDB`/`maxDB` в `commitRerender`.
- **`commitRerender`** (строки 198–210): добавить `minDB`/`maxDB` параметры → передать в `rerendered(...)` (новые опциональные параметры).
- **`setupReactiveBindings`** (строки 60–86): переделать `displayCancellable: AnyCancellable?` → `displayCancellables: Set<AnyCancellable>`; оставить существующую `CombineLatest(palette, frequencyScale)` (или упростить), и добавить отдельные `.dropFirst().receive(on:).sink { rerenderFromCache() }` для `$dynamicRangeMode`/`$autoRangeWidth`/`$manualMinDB`/`$manualMaxDB`. Дебаунс через `reapplyTask?.cancel()` уже есть.

### 4. `LiveSpectrogram.swift` (консистентность recording-preview)
- **`snapshotImage(palette:scale:)`** (строка 205): читать `RenderPreferences.shared.dynamicRangeSettings`, заменить строки 216–218 (`dynamicRange = 90`, peak-anchored) на `resolve(peak: globalMax)`. Snapshot'нуть prefs на main до рендера (функция вызывается из `RecordingView`).

### 5. `SettingsView.swift` — новая секция «Dynamic Range»
- По образцу секции frequency scale (строки 65–78): новый `Section { ... } header: { Text(L("settings.dynamics")) }`.
- `Picker(selection: $render.dynamicRangeMode)` `.segmented` → Auto / Manual.
- Условный контент: `if mode == .auto { Slider/Stepper для autoRangeWidth } else { Slider для manualMinDB, Slider для manualMaxDB }`.
- Hint-текст объясняет разницу (Auto = peak-anchored; Manual = absolute, для сравнения).
- Манипуляции с min/max в Manual режиме держать валидными (`manualMin < manualMax`, минимум 1 dB зазор) — clamp в `didSet` или UI.

### 6. Локализация (`Localization.swift` + 14 `.lproj`)
- Новые ключи: `settings.dynamics`, `settings.dynamics.auto`, `settings.dynamics.manual`, `settings.dynamics.range` (ширина), `settings.dynamics.minDB`, `settings.dynamics.maxDB`, `settings.dynamics.autoHint`, `settings.dynamics.manualHint`. Английский — основной, остальные — переводы (ru/de/es/fr/it/pt-BR/ja/ko/zh-Hans/ar/bn/hi/tr).

## Что НЕ трогаем (подтверждено агентами)
- `SpectrogramDSP.swift` — только частоты, без dB.
- `Colormap.swift` — LUT dB-агностикен.
- `AudioStats.swift` — RMS/peak/true-peak/LUFS независимы от STFT-сетки и диапазона.
- **Hover «Signal» dB** (`SpectrogramScene.swift:523`) и **measurement peak** (`:599`) — читают сырой `magnitudes` (абсолютный dBFS), остаются корректными автоматически.
- **`SpectrumSliceView` Y-axis** и **export «normalized» unit** — читают `result.minDB`/`maxDB`, автоматически follow за новым окном через расширенный `rerendered(...)` + `generate`.

## Порядок выполнения
1. `RenderPreferences` + resolver + `DynamicRangeSettings`/`Mode` (фундамент, тестируется изолированно).
2. `SpectrogramResult` (`peakDB`, `rerendered` params) + `generate` (resolver в initial load).
3. `SpectrogramModel` (`load` snapshot, `rerenderFromCache` resolve, `commitRerender`, bindings).
4. `LiveSpectrogram` (консистентность).
5. `SettingsView` секция + `Localization` (все 14 `.lproj`).
6. Сборка `xcodebuild` с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (см. AGENTS.md).

## Риски / verification
- **Default- behaviour parity:** при `.auto` + width 90 вывод идентичен текущему — проверю на существующем файле.
- **`peakDB` baked vs rerender:** при Auto-rerender окно перепривязывается к тому же baked-пику — корректно, peak от файла не зависит от окна.
- **Manual min ≥ max:** clamp + минимум 1 dB зазор, чтобы `invRange` не ушёл в `inf`.
- **Combine `dropFirst`:** при переходе на `Set<AnyCancellable>` каждый отдельный подписчик корректно дропает своё initial-emission (модель-синглтон инициализируется после prefs).