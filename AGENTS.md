# AGENTS.md

Compact orientation for OpenCode sessions. The full architecture narrative and
data-flow walkthrough live in **`CLAUDE.md`** — read it for anything beyond
quick orientation. This file only captures what an agent would otherwise get
wrong.

## What this is

Single-target macOS SwiftUI app (`SimpleSpectr.xcodeproj`) that renders an
audio-file spectrogram. No SPM/CocoaPods, no test target, no CI.

## Build / run

- Requires the **full Xcode app**, not just Command Line Tools. Prefix
  `xcodebuild` with `DEVELOPER_DIR`, or it fails:
  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project SimpleSpectr.xcodeproj -scheme SimpleSpectr \
    -destination 'platform=macOS' build
  ```
  Release `.app` lands at `build/Build/Products/Release/SimpleSpectr.app` when
  built with `-configuration Release -derivedDataPath build`.
- Normal development is Xcode Run (⌘R).
- **There are no tests.** Don't hunt for a test command. To verify DSP changes
  without the GUI, compile the engine standalone — the entry file **must** be
  named `main.swift`:
  ```sh
  xcrun swiftc SimpleSpectr/SpectrogramEngine.swift SimpleSpectr/SpectrogramDSP.swift \
    SimpleSpectr/Colormap.swift main.swift -o /tmp/tool
  ```
  `SpectrogramDSP.swift` is required — `SpectrogramEngine` references `FrequencyScale`/
  `FrequencyAxis`/`WindowFunction` from it; omitting it fails to compile.

## Repo-specific gotchas (these bite)

- **New `.swift` files need no `project.pbxproj` edits.** The target uses a
  `PBXFileSystemSynchronizedRootGroup`, so files are auto-added. The one
  exception is `Info.plist`, excluded via a
  `PBXFileSystemSynchronizedBuildFileExceptionSet` (otherwise it'd be
  double-copied as a resource). Never hand-edit the pbxproj to add sources.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** is set at the target level, so
  every type is main-isolated by default. The off-main work is explicitly marked
  `nonisolated`: `SpectrogramEngine` + private `MonoSource`, `SpectrogramDSP`
  types (`WindowFunction`/`FrequencyScale`/`MagnitudeScale`/`ChannelMode`/
  `FrequencyAxis`/`MusicNotes`), `Colormap.Palette`, `AudioStatsAnalyzer`, and
  `SpectrogramExporter` + its option enums. **Do not remove those annotations** —
  they keep the STFT, stats, and export off the MainActor; pinning them blocks
  the UI.
- **`MonoSource` derives one mono signal per `ChannelMode`** (mix / left / right /
  mid = (L+R)·½ / side = (L−R)·½, via `vDSP`); mono files collapse every mode to
  the single channel. Channel mode is an **analysis** setting — changing it
  re-decodes the file.
- **`FrequencyScale` is five cases** (linear / logarithmic / mel / bark / erb),
  each a monotonic `warp`/`unwarp` pair; the fraction↔frequency mapping
  normalizes by the warped end-points so image rows and axis labels agree.
  `isWarped` (everything but linear) tells the renderer to resample rows onto
  fractional bins. Add a scale by adding its warp pair — don't special-case the
  renderer.
- **`AVAudioFile.read(into:frameCount:)` throws at EOF** rather than returning 0
  frames. The decode loop in `MonoSource` is driven by `framePosition < length`
  reading `min(chunk, remaining)`. Switching to a `while true` + break-on-zero
  loop **crashes**.
- **Sandbox + security scope.** The app is sandboxed
  (`ENABLE_USER_SELECTED_FILES = readwrite`). Engine, player, stats analyzer,
  `AudioFileInfo`, and `RecentFilesStore` all wrap file access in
  `url.startAccessingSecurityScopedResource()`, balanced in `defer`.
- **Engine and player use different memory models — intentionally.** The engine
  streams + down-mixes to mono (`MonoSource`), never holding the whole file. The
  player *does* materialize the whole file (`AVAudioPlayer(data:)`) for instant
  seeking. Don't "fix" one to match the other.

## Conventions

- **Spectrogram orientation:** low frequencies at the bottom, high at top, time
  advances left→right. The playhead is drawn from `currentTime/duration`, and
  the spectrogram surface itself is the seek surface (click/drag to seek).
- **`SpectrogramResult.magnitudes` layout:** `[column * bins + bin]`, bin 0 =
  lowest frequency. The hover readout uses this to report exact dB without
  re-reading pixels.
- **Display vs analysis settings.** A render setting either changes the dB grid
  (**analysis** → re-decode via `reloadCurrent`: FFT size / overlap / window /
  channel mode) or only its presentation (**display-only** → cheap
  `rerenderFromCache`: palette / frequency scale / magnitude scale / dB color
  window). Overlay toggles (waveform, harmonics, follow-playhead) aren't observed
  by `SpectrogramModel` at all. Wire the new setting's Combine sink to the right
  bucket with `.receive(on: RunLoop.main)`.
- **Playhead lives on `PlayheadClock`, not the controller.** The ~60 fps time
  ticks publish on a separate `ObservableObject` so they don't rebuild
  `ContentView`'s toolbar every frame. `ContentView.onDisappear` uses `pause()`
  (not `stop()`) — minimizing to the Dock fires `onDisappear`, and `stop()`
  resets the prepared player.
- **Settings are a trailing `.inspector`,** not a `Settings` scene — toggled by
  ⌥⌘I and a toolbar button sharing one `showInspector` `@State` in
  `SimpleSpectrApp`.
- **Adding an audio format:** add the UTI to `LSItemContentTypes` in
  `SimpleSpectr/Info.plist`. Decoding is whatever Core Audio supports (no code
  change). Ogg/Opus are not supported out of the box.
- **Localization:** ~14 `.lproj` dirs with string routing centralized in
  `Localization.swift`; system language auto-detected with a Settings override.
  **`en.lproj` is the source of truth** — a missing key falls back to the English
  bundle (`enFallbackBundle`), so every key must exist in `en`, and new strings
  should be added to all `.lproj` files or they render in English.
