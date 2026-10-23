# Spatial Relay

## macOS 27 compatibility fix — confirmed working on macOS 27.2

This fork of [shevlfs/spatial-relay](https://github.com/shevlfs/spatial-relay) fixes a macOS 27 compatibility problem: the original release displayed **Fixed** and **Head Tracked** in the AirPods menu, but selecting them did not activate the requested mode. The problem was reported in [upstream issue #2](https://github.com/shevlfs/spatial-relay/issues/2).

**Confirmed working on macOS 27.2 by Aakef Khan**, who reported the issue and tested the corrected build. This confirmation applies to that setup; other macOS versions and AirPods models still need testing.

The fork makes the fix available to other users while the changes are proposed to the original project through a pull request. The original app and its foundation are by **shevlfs**; this fork contributes the compatibility changes, diagnostics and validation tools under the same MIT license.

[![CI](https://github.com/shevlfs/spatial-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/shevlfs/spatial-relay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Spatial Relay is a macOS menu-bar app that routes audio from Spotify Desktop through an Apple playback API that supports Spatialize Stereo. It is intended for AirPods models with Spatial Audio support.

```text
Spotify -> Core Audio process tap -> stereo Float32 PCM ring buffer
        -> AVSampleBufferAudioRenderer -> current output device
```

The app runs in the menu bar and has no Dock icon. Closing its panel does not stop an active relay.

## Requirements

- Apple silicon Mac
- macOS 14.2 or later
- Spatial Audio-capable AirPods
- Spotify Desktop (`com.spotify.client`)
- Xcode 16.4 or later when building from source; the macOS 27 receiver path requires Swift 6.4 and the macOS 27 SDK

## Install

Prebuilt Apple silicon packages are available on the [Releases page](https://github.com/shevlfs/spatial-relay/releases). Release builds are ad-hoc signed and are not notarized. For a normal Gatekeeper-trusted build, compile the app with your own Apple development identity.

To build locally:

1. Clone the repository.
2. Open `SpatialRelay.xcodeproj` in Xcode.
3. Select the **SpatialRelay** scheme and your Mac.
4. Choose a Development Team if Xcode requests one.
5. Run the app.

## Use

1. Connect your AirPods and select them as the Mac's output.
2. Start playback in Spotify.
3. Open Spatial Relay from its waveform icon in the menu bar.
4. Click **Start relay**.
5. Approve **System Audio Recording** access when macOS asks.
6. Open the macOS Sound or AirPods menu and select **Fixed** or **Head Tracked** under Spatial Audio.

Stop the relay before intentionally changing output devices. Use **Quit Spatial Relay** from the ellipsis menu to close the app and restore Spotify's direct output.

## Audio and privacy

The relay accepts stereo, native-endian 32-bit floating-point PCM from Core Audio and submits Float32 PCM at the output device's nominal sample rate. It does not add lossy encoding, sample-rate conversion, normalization, EQ, or gain changes. Spotify's own source quality and normalization settings still apply.

Audio remains in a bounded in-memory buffer. It is not written to disk, sent over the network, or collected as telemetry. Spotify's original output is muted only while the process tap is active. Normal stop, quit, and failure paths restore direct output.

Spatial Audio mode changes can briefly reconfigure the renderer. Spatial Relay uses the system output route and opts stereo PCM into spatialization. On macOS 27, it handles the audio receiver's configuration and automatic-flush suggestions directly. It flushes and rebases audio without pausing the live timebase during those transitions, allows a five-second recovery window, and stops safely if output does not recover. Actual playback underruns still pause and prebuffer the timeline.

Use **… → Copy diagnostics** to copy the renderer backend, output-change counters, capture counters and any error. The last diagnostics remain available after the relay stops. This does not copy recorded audio.

## Development

Run the unit tests from the command line:

```sh
xcodebuild \
  -project SpatialRelay.xcodeproj \
  -scheme SpatialRelay \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

CI runs tests, static analysis, and a Release build on a native arm64 macOS runner. Tags matching `vMAJOR.MINOR.PATCH` build an ad-hoc signed app, verify it, and publish a ZIP and SHA-256 checksum to GitHub Releases.

The hosted test suite cannot exercise the System Audio Recording prompt, Spotify playback, AirPods routing, or the Spatial Audio menu. Changes to those paths should also be checked on a physical Mac.

For a local build using Command Line Tools and the macOS 27 SDK:

```sh
bash Scripts/build-local.sh
```

This builds `build/SpatialRelay` and runs standalone checks for PCM bytes and timestamps at 44.1/48 kHz, stereo layout, invalid chunks, queue limits, recovery anchors and the capture ring. It also runs a runtime smoke test of the production player with silent PCM, including startup, enqueue, diagnostics, flush, stop/restart and destruction. If AVFoundation cannot initialize a renderer in the build environment, the runtime test reports **SKIP**, not a pass.

For physical-device validation, play Spotify through AirPods, start the relay, and choose **Fixed**, **Head Tracked**, then **Off** for Spatial Relay in the AirPods menu. Check that each selection remains active and playback continues. Also check pause/resume, stop/restart and output disconnection. Copy diagnostics if a mode does not stick or playback stops. Test the legacy renderer on macOS 14.2–26 separately from the macOS 27 receiver path.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Security reports are covered by [SECURITY.md](SECURITY.md).

## License

Spatial Relay is open source under the [MIT License](LICENSE).

Spotify, AirPods, Spatial Audio, macOS, and Apple are trademarks of their respective owners. This project is independent and is not affiliated with, endorsed by, or sponsored by Spotify or Apple.
