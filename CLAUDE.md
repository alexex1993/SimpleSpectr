# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

SimpleSpectr is a macOS SwiftUI app that renders a spectrogram of an audio file. Users open files either inside the app (button / drag-and-drop) or from Finder via "Open With" (file-type association). Decoding goes through Core Audio, so any format `AVAudioFile` supports works (wav, mp3, aac/m4a, flac, aiff, alac). Ogg/Opus are not supported by Core Audio out of the box.

## Build & run

This is an Xcode project (no SPM/CocoaPods). The command-line toolchain is *not* enough — `xcodebuild` needs the full Xcode, so prefix commands with `DEVELOPER_DIR`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project SimpleSpectr.xcodeproj -scheme SimpleSpectr \
  -destination 'platform=macOS' build
```

There are no tests. Normal development is Xcode Run (⌘R). For "Open With" to appear in Finder, the built `.app` must be registered with Launch Services (e.g. moved to `/Applications`).

To verify the DSP pipeline without the GUI, compile the engine files into a standalone tool (the entry file must be named `main.swift`):

```bash
xcrun swiftc SimpleSpectr/SpectrogramEngine.swift SimpleSpectr/Colormap.swift main.swift -o /tmp/tool
```

## Architecture

Files in `SimpleSpectr/` are compiled automatically — the Xcode target uses a `PBXFileSystemSynchronizedRootGroup`, so **new `.swift` files need no `project.pbxproj` edits**. The one exception is `Info.plist`, which is excluded from the auto-membership via a `PBXFileSystemSynchronizedBuildFileExceptionSet` (otherwise it would be double-copied as a resource).

Data flow on opening a file:

1. **`SimpleSpectrApp`** — `WindowGroup` + `.onOpenURL` (Finder open) and a ⌘O menu command that posts `.openFileRequested`. Holds the single `SpectrogramModel` `@StateObject`.
2. **`SpectrogramModel`** (`@MainActor` `ObservableObject`) — entry point `load(url:)`. Runs the engine in `Task.detached`, publishes a `State` enum (`idle`/`loading`/`loaded`/`failed`). Uses a monotonic `loadToken` so a newer load supersedes an in-flight older one.
3. **`SpectrogramEngine`** — pure, `nonisolated` static functions (must stay off the MainActor; the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are main-isolated unless marked otherwise). Pipeline: `decodeMono` (AVAudioFile → mono Float buffer) → STFT via Accelerate `vDSP` (Hann window, real FFT `vDSP_fft_zrip`, magnitude → dB) → `makeImage` (dB → color via `Colormap`, packed RGBA → `CGImage`). Returns a `SpectrogramResult` (`@unchecked Sendable` because it carries a `CGImage`).
4. **`ContentView`** / **`SpectrogramScene`** — render the result. Image orientation convention: **low frequencies at bottom, high at top, time left→right**. `SpectrogramScene` overlays frequency (kHz) and time (m:ss) axes computed from `result`, plus a `.onContinuousHover` crosshair + top-right readout (time / frequency / dB) backed by `SpectrogramResult.sample(fractionX:fractionY:)`.

`SpectrogramResult` also carries the full `magnitudes` dB grid (`[column * bins + bin]`, bin 0 = lowest freq) so the hover readout can report exact dB without re-deriving from pixels. **`PNGExport.swift`** wraps the raw spectrogram `CGImage` (no axes) as a `PNGDocument: FileDocument` for `ContentView`'s `.fileExporter`; saving via the save panel requires `ENABLE_USER_SELECTED_FILES = readwrite` (set in the target).

### Conventions / gotchas

- **AVAudioFile reading**: `read(into:frameCount:)` *throws* at EOF instead of returning 0 frames. The chunked read loop in `decodeMono` is driven by `framePosition < length` and reads `min(chunk, remaining)` — do not switch it to a `while true` + zero-frame-break loop, that crashes.
- **Engine isolation**: keep `SpectrogramEngine` methods `nonisolated`. Removing that pins them to the MainActor and blocks the UI.
- **Compute bounds**: STFT hop size is derived so column count stays ≤ `maxColumns` (default 2000); `fftSize` (default 2048) → 1024 frequency bins.
- **File access**: engine calls `startAccessingSecurityScopedResource()` (balanced in `defer`) since the app is sandboxed read-only for user-selected files.
- **Adding audio formats**: extend `LSItemContentTypes` in `SimpleSpectr/Info.plist` (UTIs) for Finder association; actual decoding is whatever Core Audio supports, no code change.
