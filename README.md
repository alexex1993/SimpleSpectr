# SimpleSpectr

A simple macOS app that displays the spectrogram of an audio file.

<img width="1798" height="948" alt="image" src="https://github.com/user-attachments/assets/92650284-3990-4df8-af71-40fcade4e43b" />


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

Audio is decoded with `AVAudioFile` (Core Audio), mixed down to mono, and transformed via a short-time Fourier transform (Hann window + real FFT) using Accelerate's `vDSP`. Magnitudes are converted to dB and mapped through an *inferno* colormap into a `CGImage`. Low frequencies are at the bottom, high at the top, and time advances left → right.
