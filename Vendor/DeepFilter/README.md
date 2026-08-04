# Vendored libDF (DeepFilterNet 3)

`lib/libdf.dylib` is a prebuilt copy of libDF's C API (`capi` cargo feature) from
https://github.com/Rikorose/DeepFilterNet, built locally on 2026-08-04 from a fresh clone
(no source changes) with:

```
cargo build --release --no-default-features --features capi
```

from the `libDF/` crate directory. Rust toolchain via `rustup` (stable-aarch64-apple-darwin).

The resulting dylib's install name was changed once, after building:

```
install_name_tool -id "@rpath/libdf.dylib" libdf.dylib
```

`model/DeepFilterNet3_onnx.tar.gz` is the upstream pretrained DeepFilterNet3 model
(`models/DeepFilterNet3_onnx.tar.gz` in the same repo), copied verbatim.

Only depends on `/usr/lib/libiconv.2.dylib` and `/usr/lib/libSystem.B.dylib` (both always
present on macOS) — no torch, no Python, no other runtime dependency.

`include/deep_filter.h` is hand-written (not cbindgen-generated) and only declares the four
functions this app calls: `df_create`, `df_get_frame_length`, `df_process_frame`, `df_free`.
See `libDF/src/capi.rs` upstream for the full C API surface if more is needed later.

To rebuild from a newer upstream version, re-clone, rebuild with the same command, redo the
`install_name_tool -id` step, and replace `lib/libdf.dylib` here.
