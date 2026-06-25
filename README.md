# SimpleSpectr

A simple macOS app that displays the spectrogram of an audio file.

<img width="909" height="481" alt="Screenshot — 2026-06-23 at 19 18 54" src="https://github.com/user-attachments/assets/280a28a1-bb87-4bb8-b1d1-06c623530517" />


## Features

- **Open from the app** — click the toolbar button or drag-and-drop an audio file onto the window.
- **Open from Finder** — right-click a file → *Open With* → *SimpleSpectr* renders the spectrogram immediately.
- **Wide format support** — anything Core Audio can decode: WAV, MP3, AAC/M4A, FLAC, AIFF, ALAC, and more.
- **Hover readout** — move the cursor over the spectrogram to read the exact time, frequency, and signal level (dB) at that point, with a crosshair.
- **PNG export** — save the rendered spectrogram to a PNG file.

## Download

Grab the latest build from the **[Releases page](https://github.com/alexex1993/SimpleSpectr/releases/latest)**.

1. Download `SimpleSpectr-<version>-macos.zip`, unzip it, and move `SimpleSpectr.app` to `/Applications`.
2. The app is not signed with an Apple Developer ID, so Gatekeeper may warn you on first launch. Either right-click the app → *Open*, or clear the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/SimpleSpectr.app
   ```

## Building from source

Requires Xcode (the full app, not just Command Line Tools).

Open `SimpleSpectr.xcodeproj` in Xcode and press Run (⌘R), or build a Release `.app` from the command line:

```sh
xcodebuild -project SimpleSpectr.xcodeproj -scheme SimpleSpectr \
  -configuration Release -derivedDataPath build
# → build/Build/Products/Release/SimpleSpectr.app
```

## How it works

Audio is decoded with `AVAudioFile` (Core Audio) and **streamed** through the analyzer, so long files are never loaded into memory in full. It is mixed down to mono and transformed via a short-time Fourier transform (Hann window + real FFT) using Accelerate's `vDSP`. The one-sided spectrum is amplitude-normalized and window-corrected, magnitudes are converted to dB, and mapped through a perceptual *inferno* colormap (interpolated in Oklab space) into a `CGImage`. Low frequencies are at the bottom, high at the top, and time advances left → right.

## License

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). Free for non-commercial use (personal, educational, research, hobby). Commercial use requires a separate license from the author.

## Changelog

### 1.7

- **Colormap picker** — choose the spectrogram palette in Settings (Inferno, Viridis, Magma, Plasma, Turbo, Cividis, Grayscale) with live gradient previews; the selection persists across launches.
- **More languages** — added 12 new localizations: Arabic, Bengali, German, Spanish, French, Hindi, Italian, Japanese, Korean, Portuguese (Brazil), Turkish, Chinese (Simplified).

### 1.5

- **Audio playback** — a player appeared at the bottom of the window that plays the file shown in the spectrogram.
- **Synced cursor** — a vertical playhead line moves across the spectrogram in sync with the sound; clicking and dragging on the spectrogram seeks through the file.
- **Pause & seek** — a Play/Pause button and a seek slider showing the current and total time.
- **Mute** — a Mute toggle: with or without sound (muted mode works as before — spectrogram only).

### 1.2

- **Localization (Russian / English)** — automatic detection of the system language plus a selector in Settings; all UI elements and units of measurement are localized.

### 1.1

- **Accurate dB readout** — the FFT is now amplitude-normalized (one-sided, Hann-window-corrected), and the DC bin is no longer contaminated by the Nyquist term. The hover readout reports true dBFS values.
- **Lower memory use** — audio is decoded and analyzed as a stream instead of materializing the whole file; very long files no longer risk running out of memory.
- **Faster rendering** — hoisted FFT scratch buffers, a 256-entry colormap LUT, and zero-copy pixel packaging.
- **Perceptual colormap** — *inferno* is interpolated in Oklab space for smoother, more accurate gradients.
- **Cancellable loads** — opening a new file cancels the previous in-flight analysis instead of wasting CPU.
- **Better drag-and-drop** — non-file drops are rejected instead of silently failing.
- **Smarter hover readout** — the time/frequency/dB panel flips to the opposite quadrant so it never covers the crosshair.
- Reliability: `fftSize` is validated as a power of two; `CGImage`/`CGDataProvider` failures are handled instead of force-unwrapped.

### 1.0

- Initial release.
