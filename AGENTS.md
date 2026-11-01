# AGENTS.md

Practical repository guidance for Codex. SimpleSpectr is a single-target macOS
SwiftUI app for audio spectrograms, playback, recording, measurements and export.
It uses Core Audio formats (including WAV, MP3, AAC/M4A, FLAC, AIFF and ALAC);
Ogg/Opus are not supported out of the box. There is no SPM, CocoaPods, test
target or CI.

## Build and verification

Use full Xcode, not just Command Line Tools:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SimpleSpectr.xcodeproj -scheme SimpleSpectr \
  -destination 'platform=macOS' build
```

Normal development uses Xcode Run (⌘R). With `-configuration Release
-derivedDataPath build`, the app lands at
`build/Build/Products/Release/SimpleSpectr.app`. Finder's Open With requires
the built app to be registered with Launch Services (e.g. in `/Applications`).
There are no tests. For a standalone DSP check, provide an entry file named
`main.swift` and compile all three source files:

```sh
xcrun swiftc SimpleSpectr/SpectrogramEngine.swift SimpleSpectr/SpectrogramDSP.swift \
  SimpleSpectr/Colormap.swift main.swift -o /tmp/tool
```

## Architecture and invariants

- The target uses `PBXFileSystemSynchronizedRootGroup`: new Swift files are
  auto-added; do not edit `project.pbxproj` to add sources. `Info.plist` is
  excluded via a build-file exception to avoid copying it twice.
- `SimpleSpectrApp` owns the single `SpectrogramModel` and `showInspector`.
  Finder opens use `.onOpenURL`; settings live in a trailing `.inspector`,
  toggled by ⌥⌘I and the toolbar, not a Settings scene.
- `SpectrogramModel` snapshots settings on the MainActor, runs analysis in a
  detached task and publishes idle/loading/loaded/failed state. `loadToken`
  discards stale results; `lastURL` survives re-analysis. Key per-file UI resets
  to `lastURL`, not `loaded?.url`, so re-analysis does not reset playback.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Preserve explicit `nonisolated`
  on off-main DSP and export code: `SpectrogramEngine`, private `MonoSource`,
  DSP types, `Colormap.Palette`, `AudioStatsAnalyzer`, `SpectrogramExporter`
  and its option enums. The recording tap must capture only Sendable/off-main
  objects, never the MainActor controller.
- The engine streams audio through `MonoSource`, derives a mono signal and
  performs windowed, amplitude-normalized STFT; it checks cancellation between
  columns. Mix/Left/Right/Mid/Side select the signal; mid = (L+R)/2 and side =
  (L−R)/2. Mono input collapses all modes to its single channel. The player
  intentionally loads the whole file into `AVAudioPlayer(data:)` for seeking.
- `AVAudioFile.read(into:frameCount:)` throws at EOF. Drive chunked reads in
  `MonoSource` and `AudioStatsAnalyzer` with `framePosition < length` and
  `min(chunk, remaining)`; a zero-frame-terminated loop can crash.
- FFT size must be a power of two; it yields `fftSize/2` bins. The hop is the
  larger of the overlap-derived hop and the hop needed to cap columns at
  `maxColumns` (default 2000). Window functions are normalized by coherent sum
  to preserve amplitude calibration.
- `SpectrogramResult.magnitudes` is a column-major dB grid
  `[column * bins + bin]`, bin 0 lowest, always on the linear FFT bin grid
  regardless of display scale. Hover, slices and data export use this grid;
  per-column waveform minima/maxima align with its time axis. Low frequencies
  are at the bottom, high at the top, and time runs left to right.
- `FrequencyScale` implements linear, logarithmic, mel, bark and erb using
  monotonic `warp`/`unwarp` pairs. `FrequencyAxis` normalizes warped endpoints
  so renderer, axes and sampling agree; warped scales resample fractional bins.
  Log starts at A0 (27.5 Hz) and uses note labels; the others start at 0 Hz.
  Add scales through a warp pair, not renderer special cases.
- Analysis settings (FFT size, overlap, window, channel mode) call
  `reloadCurrent()` and re-decode. Display settings (palette, frequency scale,
  magnitude scale, dB floor/ceiling/reference level) call `rerenderFromCache()`.
  `colorWindow` incorporates reference gain. Overlay toggles for waveform,
  harmonics and follow-playhead are observed by the scene, not the model. Use
  `.receive(on: RunLoop.main)` in settings sinks because `@Published` emits in
  `willSet`; preserve the pending display refresh when a load is in flight.
- `PlayheadClock` publishes ~60 fps time separately from the player controller
  to avoid rebuilding the toolbar. The spectrogram surface handles click/drag
  seeking; follow-playhead scrolls the zoomed plot. `ContentView.onDisappear`
  calls `pause()`, not `stop()`: minimizing triggers it and stop resets playback.
- `AudioRecorderController` records to lossless FLAC in Application Support via
  an audio-thread tap; `LiveSpectrogram` supplies the preview. On stop, the
  recording goes through normal `load(url:)` and can be saved elsewhere.
  Recording needs the audio-input entitlement and `NSMicrophoneUsageDescription`.
- Measurements use `AudioStatsAnalyzer` on raw samples, not the STFT grid, for
  RMS, dBFS, 4× true peak dBTP and integrated LUFS. Spectrum slices use the
  cached grid. `SpectrogramExporter` produces CSV/JSON and marker CSV; PNG export
  wraps the image, optionally with axes. Recent files use security-scoped
  bookmarks; markers are session data. `AudioFileInfo` loads metadata off-main
  and leaves localization of raw Core Audio flags to the UI.
- Video export snapshots the grid and palette for a detached task. `.flyover`
  uses `SpectrogramVideoRenderer` and `.bars` uses `SpectrumBarsVideoRenderer`;
  both share writer setup, audio pump, back-pressure and cancellation via the
  private `FramePainter` seam in `SpectrogramVideoExport.swift`. Add styles at
  that seam. Shaders compile from source at runtime; no `.metal` file is needed.
  Bars use the displayed frequency axis, except linear uses a Mel spread; their
  animator retains envelope and peak state between frames.

## File access and localization

- The app is sandboxed with `ENABLE_USER_SELECTED_FILES = readwrite`. Engine,
  player, stats, `AudioFileInfo` and recent-file access balance
  `startAccessingSecurityScopedResource()` with `defer`.
- Add Finder file associations as UTIs in `SimpleSpectr/Info.plist` under
  `LSItemContentTypes`; Core Audio determines decoding support.
- Route user-facing strings through `L(...)` in `Localization.swift`. The
  system language is automatic with a settings override. English is the fallback
  and source of truth: add every new key to `en.lproj` and all other `.lproj`
  files so untranslated strings do not fall back to English.
