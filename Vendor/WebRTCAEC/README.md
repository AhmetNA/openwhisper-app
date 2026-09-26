# WebRTC AEC3 bridge

This directory contains the C bridge and arm64 static archive used by OpenWhisper's optional
AEC3 linear echo-cancellation engine. It is built from `webrtc-audio-processing` v2.1 (WebRTC
M131) and the bundled Abseil 20240722.0 fallback.

The bridge intentionally exports `EchoCanceller3`'s linear output. The residual suppressor's
full output damages the wake-word score in the project's benchmark and must not be used here.

Rebuild the archive from the repository root:

```sh
./tools/aec3-bench/build-vendor.sh
```

The resulting archive is currently arm64-only. Upstream license and patent notices are stored
in `LICENSE.webrtc` and `PATENTS.webrtc`.
