# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

SimpleSpectr is a macOS SwiftUI app that renders a spectrogram of an audio file. Users open files inside the app (button / drag-and-drop), from Finder via "Open With" (file-type association), or by recording from the microphone (live spectrogram). Decoding goes through Core Audio, so any format `AVAudioFile` supports works (wav, mp3, aac/m4a, flac, aiff, alac). Ogg/Opus are not supported by Core Audio out of the box.

Beyond viewing, the app does numeric analysis: a hover readout (time/frequency/dB), a 1-D spectrum slice per STFT column, a draggable measurement region with true amplitude statistics (RMS, dBFS, dBTP, LUFS), session markers, and data export to CSV/JSON/PNG. The presentation is tunable: five frequency scales (linear, logarithmic, and the perceptual Mel/Bark/ERB), a magnitude mode (dB vs linear amplitude), a per-channel view of stereo material (Mix/Left/Right/Mid/Side), an adjustable dB color window with a reference-level gain, and a follow-playhead auto-scroll. There is a sibling `AGENTS.md` with a condensed version of the gotchas below.

## Build & run

This is an Xcode project (no SPM/CocoaPods). The command-line toolchain is *not* enough — `xcodebuild` needs the full Xcode, so prefix commands with `DEVELOPER_DIR`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project SimpleSpectr.xcodeproj -scheme SimpleSpectr \
  -destination 'platform=macOS' build
```

A Release `.app` lands at `build/Build/Products/Release/SimpleSpectr.app` when built with `-configuration Release -derivedDataPath build`.

There are no tests — don't hunt for a test command. Normal development is Xcode Run (⌘R). For "Open With" to appear in Finder, the built `.app` must be registered with Launch Services (e.g. moved to `/Applications`).

To verify the DSP pipeline without the GUI, compile the engine files into a standalone tool (the entry file must be named `main.swift`):

```bash
xcrun swiftc SimpleSpectr/SpectrogramEngine.swift SimpleSpectr/SpectrogramDSP.swift \
  SimpleSpectr/Colormap.swift main.swift -o /tmp/tool
```

## Architecture

Files in `SimpleSpectr/` are compiled automatically — the Xcode target uses a `PBXFileSystemSynchronizedRootGroup`, so **new `.swift` files need no `project.pbxproj` edits**. Never hand-edit the pbxproj to add sources. The one exception is `Info.plist`, excluded from auto-membership via a `PBXFileSystemSynchronizedBuildFileExceptionSet` (otherwise it would be double-copied as a resource).

### File-open data flow

1. **`SimpleSpectrApp`** — `WindowGroup` + `.onOpenURL` (Finder open), a ⌘O command that sets `model.openRequested`, an *Open Recent* menu driven by `RecentFilesStore`, and a custom About panel. Holds the single `SpectrogramModel` `@StateObject` **and the `showInspector` `@State`** (settings-panel visibility). Settings are no longer a separate `Settings` scene: a `CommandGroup(after: .sidebar)` adds a **⌥⌘I** toggle that flips `showInspector`, and the same binding is passed into `ContentView` for its toolbar toggle. (The old `Settings { SettingsView() }` scene was removed.)
2. **`SpectrogramModel`** (`@MainActor` `ObservableObject`) — entry point `load(url:)`. Snapshots the MainActor-isolated render settings, runs the engine in `Task.detached`, and publishes a `State` enum (`idle`/`loading`/`loaded`/`failed`) plus `fileInfo`. A monotonic `loadToken` makes a newer load supersede an in-flight older one (`finish` drops stale tokens).
3. **`SpectrogramEngine`** — pure, `nonisolated` static functions (must stay off the MainActor; the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are main-isolated unless marked otherwise). `generate(url:fftSize:overlapPercent:windowFunction:frequencyScale:maxColumns:palette:minDB:maxDB:channelMode:magnitudeScale:)` opens the file, runs a streaming STFT (windowed via `SpectrogramDSP`, real FFT `vDSP_fft_zrip`, amplitude-normalized magnitude → dB) and renders to a `CGImage` via `Colormap`. `minDB`/`maxDB` are the caller-supplied color window (defaults span −90…0 dBFS; the old fixed "90 dB below peak" auto-range is gone). `channelMode` selects which signal `MonoSource` derives from a stereo file, and `magnitudeScale` picks dB vs linear amplitude mapping in `renderImage`. `renderImage(...)` is split out so the model can re-color/re-scale from the cached dB grid without re-decoding. A private `MonoSource` streams the file forward chunk-by-chunk and derives a mono signal on demand (Mix down-mix, single-channel Left/Right, or Mid/Side sum·½/difference·½ via `vDSP`), so the whole file is never held in memory; `Task.checkCancellation()` is honored between columns. Returns a `SpectrogramResult` (`@unchecked Sendable` because it carries a `CGImage`).
4. **`ContentView`** / **`SpectrogramScene`** — render the result. Orientation convention: **low frequencies at bottom, high at top, time left→right**. `SpectrogramScene` overlays frequency and time axes (`SpectrogramAxes`), a `.onContinuousHover` crosshair + readout, the harmonic-overtone cursor, the playhead, and the click/drag-to-seek and measurement-region surfaces; it also drives **follow-playhead auto-scroll** (`ScrollPosition` + `onScrollGeometryChange`, `followPlayheadIfNeeded` keeps the playhead pinned inside the visible edge while playing a zoomed plot). `ContentView` also hosts the toolbar (including a "View Options" menu with quick channel/magnitude pickers and a sidebar toggle), the trailing settings `.inspector` (hosting `SettingsView`), `PlayerBar`, waveform overview lane, and the export sheet. Per-file UI reset (markers, zoom, player) is keyed off `model.lastURL`, **not** `loaded?.url`, so a re-analysis (which briefly leaves `.loaded`) doesn't tear down playback.

### SpectrogramResult — the shared grid

`SpectrogramResult` carries everything downstream features need without re-decoding:
- `magnitudes` — column-major dB grid `[column * bins + bin]`, bin 0 = lowest freq. **Always stored on the *linear* bin grid** regardless of the displayed `frequencyScale`, so hover/slice/export and a scale re-render stay exact. `sample(fractionX:fractionY:)` resolves a hover point; `rerendered(image:scale:...)` swaps the presented image while keeping the grid.
- `waveformMin`/`waveformMax` — per-column sample envelope (length == columns), driving the overview waveform lane 1:1 with the time axis.
- `minDB`/`maxDB`, `frequencyScale`, `minDisplayedFrequency` — the color and axis mapping the image was rendered with. `frequencyAxis` rebuilds the `FrequencyAxis` for sampling. `rerendered(...)` can now also swap in a new `minDB`/`maxDB` so a color-window change re-presents the cached grid without re-decoding.

### Settings → reactive reload pipeline

`ColormapPreferences`, `RenderPreferences`, and `LocalizationManager` are `@MainActor` shared singletons backed by `@AppStorage`/`UserDefaults`. `SpectrogramModel.setupReactiveBindings()` wires Combine subscriptions that split changes by cost:
- **Display-only** (palette, frequency scale, magnitude scale, and the color-window trio `dbFloor`/`dbCeiling`/`referenceLevel`) → `rerenderFromCache()` re-colors the cached grid via `renderImage`; no audio re-decode. These are combined into one sink (a `CombineLatest3` of palette, a scale-pair `presentation`, and a levels `CombineLatest3`).
- **Analysis** (FFT size, overlap, window function, **channel mode**) → `reloadCurrent()` re-runs `generate` on `lastURL` (tracked separately from `state` so it works mid-load). Channel mode changes the derived mono signal, so it must re-decode.

`RenderPreferences.colorWindow` folds `referenceLevel` (a dB gain) into `dbFloor`/`dbCeiling` and is what the model passes as `minDB`/`maxDB`; `resetLevels()` restores the trio to factory. `followPlayhead`, `showWaveform`, and `showHarmonics` are pure overlay toggles the model deliberately does **not** observe (the scene reacts to them directly).

Note the `.receive(on: RunLoop.main)` on each sink: `@Published` emits in `willSet`, so the sink must defer a runloop turn to read the *new* stored value. If a display change arrives while a load is in flight, `needsDisplayRefresh` re-renders once the load lands.

### DSP module (`SpectrogramDSP`)

Shared `nonisolated` types used by both the engine and the UI: `WindowFunction` (Hann/Blackman-Harris/Kaiser/flattop, each normalized by its coherent sum so amplitude stays calibrated), `FrequencyScale` (linear/logarithmic/mel/bark/erb), `MagnitudeScale` (logarithmic dB / linear amplitude), `ChannelMode` (mix/left/right/mid/side), `FrequencyAxis` (maps a 0…1 vertical fraction ⇄ frequency ⇄ FFT bin — the renderer and the hover sample share it so image and axis always agree; log axis anchors at A0 = 27.5 Hz), and `MusicNotes` (A4 = 440 Hz helpers for the note overlay).

`FrequencyScale` expresses every scale as a monotonic `warp`/`unwarp` pair (linear = identity, log = `ln`/`exp`, Mel = `2595·log₁₀(1+f/700)`, Bark = Traunmüller, ERB = Glasberg-Moore); `frequency(forFraction:)`/`fraction(forFrequency:)` interpolate linearly between the warped end-points so image rows and axis labels always agree. `isWarped` is true for every scale except linear (the renderer resamples each output row onto a fractional bin); `usesNoteLabels` is true only for log. Linear and the perceptual scales anchor at 0 Hz; log anchors at A0. `SpectrogramAxes` draws a note-labelled axis for log, evenly-warped Hz ticks for mel/bark/erb, and plain Hz ticks for linear. **`MagnitudeScale` and the color window are display-only** (re-color from cache); **`ChannelMode` is analysis** (re-decode).

### Playback (`AudioPlayerController`)

`@MainActor` `ObservableObject` that plays the loaded file (`AVAudioPlayer` from in-memory `Data`). The ~60 fps playhead position lives on a **separate `PlayheadClock` `ObservableObject`** (`playhead.time`, mirrored by the controller's `currentTime` computed property), so per-tick invalidation only touches views that draw the playhead (`SpectrogramScene`, `PlayerBar`) — **not** `ContentView`. That split matters: publishing time on the controller itself rebuilt the toolbar every tick and tore down the open View-Options menu, so its pickers were unusable during playback. A `Timer` (main run loop, common mode) polls at ~60 fps; natural EOF is detected by `isPlaying && !player.isPlaying`. `PlayerBar` shows play/pause, times, seek, and a mute toggle. The spectrogram surface is the navigation surface — click/drag seeks. **`ContentView.onDisappear` calls `pause()`, not `stop()`** — minimizing to the Dock fires `onDisappear` on macOS, and `stop()` undoes `prepareToPlay()` and resets position, leaving playback broken until reload.

### Recording & live spectrogram

`AudioRecorderController` (`@MainActor`) records the mic to a lossless **FLAC** in Application Support (`SimpleSpectr/Recordings`) via an `AVAudioEngine` input tap. The tap runs on the audio thread and must never touch the `@MainActor` controller — it only writes to the file and feeds a `LiveSpectrogram` (a streaming STFT that builds a preview `CGImage`). A 20 fps main-runloop timer pulls the preview image + elapsed time. On stop, the FLAC is reopened through the normal `load(url:)` path, so the recording gets the full analysis UI; `isRecordingURL` drives a "Save recording" affordance to copy it out. `RecordingView`/`LiveSpectrogram` host this.

### Measurements & export

- **`AudioStats`** (`AudioStatsAnalyzer`, `nonisolated`) — for a `[start,end)` time selection, re-reads the **raw samples** (independent of the STFT grid, so numbers match the source) and computes RMS, sample peak dBFS, 4× oversampled true peak dBTP, and ITU-R BS.1770 integrated loudness LUFS. `Measurement`/`MeasurementModel` drive the drag-region panel.
- **`SpectrumSliceView`** — double-click pops a 1-D amplitude-vs-frequency plot of one STFT column, read from the cached grid.
- **`SpectrogramExport`** (`SpectrogramExporter`, pure `nonisolated`) — serializes the dB grid to CSV (freq × time matrix) or JSON (grid + metadata), with range clamping, decimation caps, units (dB/linear/normalized), and locale-aware delimiters; also exports markers as CSV. **`PNGExport`** wraps the `CGImage` (with/without axes) as a `PNGDocument: FileDocument`. `ExportDialog` is the unified sheet driving `ContentView`'s `.fileExporter`.
- **`MarkersStore`** / **`RecentFilesStore`** — session markers (time + label) and recent files (persisted via security-scoped bookmarks).
- **`AudioFileInfo`** — metadata for the toolbar info popover, loaded off-main (so it stores *raw* Core Audio flags and lets the popover localize on the MainActor). Beyond the basics it exposes `container` (uppercased extension), `frameCount`, `framesPerPacket` (only for packetized/compressed codecs), `isLossless` (PCM/ALAC/FLAC), the raw PCM `pcmIsFloat`/`pcmBigEndian` flags, and a computed `nyquist` (sampleRate / 2). The popover renders these as extra rows (Container, Compression lossless/lossy, Sample format e.g. "Float · 32-bit · LE", Nyquist, Frames per packet, Total frames).

### Conventions / gotchas

- **AVAudioFile reading**: `read(into:frameCount:)` *throws* at EOF instead of returning 0 frames. The chunked read loops (`MonoSource.decodeNextChunk`, `AudioStatsAnalyzer.analyze`) are driven by `framePosition < length` reading `min(chunk, remaining)` — do not switch them to `while true` + zero-frame-break, that crashes.
- **Engine isolation**: keep `SpectrogramEngine`, `Colormap`, `SpectrogramDSP` types, `AudioStatsAnalyzer`, `SpectrogramExporter`, and the private `MonoSource` `nonisolated`. Removing that pins them to the MainActor and blocks the UI. The recording tap closure must capture only Sendable / off-main objects, never the controller.
- **Display vs analysis settings**: when adding a render setting, decide whether it changes the dB grid (→ re-decode via `reloadCurrent`) or only its presentation (→ cheap `rerenderFromCache`), and wire the Combine sink accordingly with `.receive(on: RunLoop.main)`. Current split: analysis = FFT size / overlap / window / **channel mode**; display-only = palette / frequency scale / magnitude scale / **dB color window (floor, ceiling, reference level)**. Overlay toggles (waveform, harmonics, follow-playhead) aren't observed by the model at all.
- **Compute bounds**: STFT hop is the larger of the overlap-derived hop and the hop needed to keep columns ≤ `maxColumns` (default 2000). `fftSize` (default 2048, power-of-two enforced by `SpectrogramError.invalidFFTSize`) → `fftSize/2` frequency bins.
- **File access**: the engine, stats analyzer, and player call `startAccessingSecurityScopedResource()` (balanced in `defer`) since the app is sandboxed read-only for user-selected files. Saving via the export panel requires `ENABLE_USER_SELECTED_FILES = readwrite`; recording requires the audio-input entitlement + `NSMicrophoneUsageDescription`. Both are set already.
- **Player vs engine memory model — intentionally different**: the engine streams + down-mixes (never holds the whole file); the player materializes the whole file (`AVAudioPlayer(data:)`) for instant seeking. Don't "fix" one to match the other.
- **Adding audio formats**: extend `LSItemContentTypes` in `SimpleSpectr/Info.plist` (UTIs) for Finder association; decoding is whatever Core Audio supports, no code change.
- **Localization**: ~14 `.lproj` dirs; string routing is centralized through `Localization.swift`'s `L(...)` helper, system language auto-detected with a `LocalizationManager` (Settings) override. User-facing strings go through `L(...)`, not hardcoded. A missing key falls back to the **English bundle** (`enFallbackBundle`), so an untranslated string surfaces as English rather than a raw `dotted.identifier` — meaning **`en.lproj` is the source of truth and must always carry every key**. When adding a UI string, add it to `en` first, then all other `.lproj` files.
