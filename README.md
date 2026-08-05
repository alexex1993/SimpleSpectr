# SimpleSpectr

A simple macOS app that displays the spectrogram of an audio file.

**[simplespectr.alexnew.ru](https://simplespectr.alexnew.ru/)** — website with screenshots and downloads.

<img width="2024" height="1088" alt="image" src="https://github.com/user-attachments/assets/530fa66d-5dd1-41f1-8b3e-3ac83323f1fd" />


## Features

- **Open from the app** — click the toolbar button or drag-and-drop an audio file onto the window.
- **Open from Finder** — right-click a file → *Open With* → *SimpleSpectr* renders the spectrogram immediately.
- **Microphone input / live spectrogram** — record from the microphone and watch a full-screen live spectrogram grow in real time; the captured FLAC is reopened through the normal analysis path, so you get axes, hover readout, crosshair, and playback on what you just recorded. A *Save Recording…* toolbar button copies the take out of the app's storage to anywhere you like.
- **Wide format support** — anything Core Audio can decode: WAV, MP3, AAC/M4A, FLAC, AIFF, ALAC, and more.
- **Analysis controls** — tune the STFT itself: **FFT window size** (256 – 16384), **overlap** (0 / 25 / 50 / 75 / 87.5 %), and the **window function** — *Hann* (balanced default), *Blackman-Harris* (strong sidelobe suppression), *Kaiser* (β = 8.6, steep rolloff), or *Flattop* (most accurate amplitude). Each window is normalized by its coherent sum, so the dB readout stays calibrated whichever you pick. Larger windows resolve pitch, smaller ones resolve transients.
- **Channel mode** — analyze a stereo file as **Mix** (mono down-mix), **Left**, **Right**, the **Mid / Side** (M/S) sum and difference, **Stereo (L/R stacked)** with the two spectrograms drawn one above the other, or **Correlation (L↔R)** that colors a single plot by how the channels relate at each frequency (red = anti-phase, blue = in phase). The mono-derivation modes use a single FFT; the dual modes transform L and R in one pass. Mono files collapse every mode to the single channel.
- **Frequency scales** — five mappings for the frequency axis: **Linear**, **Logarithmic** (with note names, A4 = 440 Hz), **Mel**, **Bark**, and **ERB**. Each perceptual scale warps the rows so the labels and the image always agree.
- **Magnitude scale** — map the spectrogram values in **log (dB)** (the readable default) or **Linear** amplitude.
- **Color window & reference level** — set the min/max dB of the colormap and a reference-level gain that brightens quiet material. All three are display-only and re-render instantly without re-analyzing the file.
- **Hover readout** — move the cursor over the spectrogram to read the exact time, frequency, and signal level (dB) at that point, with a crosshair. In the stacked-stereo view it also names the pane (Left / Right) under the cursor; in correlation mode it reads out the L↔R correlation value.
- **Waveform overview** — a time-domain amplitude lane sits above the spectrogram, locked to the same time axis and zoom, so you can see the track's overall dynamics and relate them to the frequency view below.
- **Harmonic cursor** — switch on the overlay and hovering paints faint guide lines at the overtone series (2×, 3×, 4×… the frequency under the cursor), making it easy to tell pitched harmonic content from inharmonic noise.
- **Measure region** — switch on measure mode in the header and drag a rectangle across the spectrogram for an instant measurement panel: Δtime, Δfrequency, the musical interval, the loudest cell, and true amplitude statistics (RMS, sample peak dBFS, 4× oversampled true peak dBTP, and ITU-R BS.1770 integrated loudness LUFS) computed from the raw samples.
- **Spectrum slice** — double-click any point in time to pop open a 1-D amplitude-vs-frequency plot of that exact STFT column, useful for reading peak frequencies and the spectral shape at a single instant.
- **Audio playback** — a player at the bottom of the window plays the file shown in the spectrogram, with a Play/Pause button and a seek slider showing current and total time; a Mute toggle works as a spectrogram-only mode.
- **Follow playhead** — during playback the plot auto-scrolls to keep the playhead in view once it reaches the edge; a backward seek scrolls back too. Toggle it off to scroll freely.
- **Synced cursor** — a vertical playhead line moves across the spectrogram in sync with the sound; clicking and dragging on the spectrogram seeks through the file.
- **Horizontal time zoom** — stretch the spectrogram along the time axis with **+ / −** (or the zoom controls, which show the live zoom factor and a *Fit Width* button to snap back), with the frequency axis pinned on the left while the plot scrolls.
- **Overlay toggles in the header** — one row of buttons switches the waveform lane, the harmonic cursor, follow-playhead, and measure mode on or off without opening Settings.
- **Markers / annotations** — drop labelled markers on the time axis (press **M** or use the Markers popover), then rename or delete them; markers live for the current session.
- **File info panel** — a toolbar button shows the source file's container, codec, lossless/lossy compression, PCM sample format, sample rate, Nyquist frequency, channels, bit depth, bitrate, frames per packet, duration, total frames, and size.
- **Data export** — a single export sheet lets you pick the format — **CSV**, **JSON**, **PNG**, or **Markers** — and tune options (time/frequency range, units, time-column and frequency-bin decimation caps with a live cell count, delimiter/decimal mark/precision, headers, axes). CSV/JSON dump the actual STFT magnitudes; Markers exports your annotations; PNG saves the rendered image.
- **Video export, two styles** — render the spectrogram as a share-ready `.mp4` for social media, muxed with the original audio. **3D flyover** flies a camera over a moving 3D landscape (X = frequency, Z = time, Y = magnitude); **2D bars** is the classic flat visualizer — a row of segmented (LED) bars over a glowing baseline with a mirrored reflection, with controls for bar count, peak height, glow, smoothing, segments and mirror, and optional custom background/bar colors. Pick an aspect ratio (**16:9** landscape for YouTube, **9:16** vertical for Reels/TikTok/Shorts, or **1:1** for feed posts), resolution (720p – 4K), frame rate (30/60), plus per-style drama (camera tilt/drift/peak height, or the bar controls) and backdrop layers (star field, neon floor grid, pulse-with-the-music). All colors are derived from the active colormap so the clip always matches the spectrogram. H.264 up to 1080p, HEVC at 1440p/4K.
- **Colormap picker** — choose the spectrogram palette in Settings from nine colormaps (Inferno, Viridis, Magma, Plasma, Turbo, Cividis, Jet, Hot, Grayscale) with live gradient previews; the selection persists across launches. Correlation mode uses its own diverging red↔blue map.
- **Settings inspector** — analysis and display options live in a trailing inspector panel, toggled from the toolbar or with **⌥⌘I**. Channel and magnitude also get a quick picker in the toolbar.
- **Recent files** — *File → Open Recent* reopens recently analyzed files across launches via security-scoped bookmarks.
- **Keyboard shortcuts** — **Space** play/pause, **← / →** seek ±5 s, **+ / −** zoom, **M** add marker, **Esc** close the spectrum slice, **⌘O** open a file, **⌥⌘I** toggle Settings.
- **Localization** — 14 languages (Arabic, Bengali, German, Spanish, French, Hindi, Italian, Japanese, Korean, Portuguese (Brazil), Turkish, Chinese (Simplified), Russian, English) with automatic detection and a Settings override.

## Download

Grab the latest build from the **[Releases page](https://github.com/alexex1993/SimpleSpectr/releases/latest)**. Requires **macOS 26.5 or later**.

1. Download `SimpleSpectr-<version>-macos.dmg`, open it, and drag `SimpleSpectr.app` into the `Applications` folder shown beside it.
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

Audio is decoded with `AVAudioFile` (Core Audio) and **streamed** through the analyzer, so long files are never loaded into memory in full. The selected channel derivation (mix, L, R, M/S — or both channels for the stereo/correlation modes) is transformed via a short-time Fourier transform (the chosen window + real FFT) using Accelerate's `vDSP`. The one-sided spectrum is amplitude-normalized and window-corrected, magnitudes are converted to dB, and mapped through the active perceptual colormap (interpolated in Oklab space) into a `CGImage`. The dB grid is cached, so changing the palette, frequency scale, magnitude mapping, or color window re-renders instantly without re-decoding the audio. Low frequencies are at the bottom, high at the top, and time advances left → right.

## License

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). Free for non-commercial use (personal, educational, research, hobby). Commercial use requires a separate license from the author.