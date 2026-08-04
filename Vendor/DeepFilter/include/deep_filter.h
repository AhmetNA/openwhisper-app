// Minimal hand-written header for libDF's C API (Rikorose/DeepFilterNet, libDF/src/capi.rs).
// Only the functions this app actually calls are declared.
#ifndef OPENWHISPER_DEEP_FILTER_H
#define OPENWHISPER_DEEP_FILTER_H

#include <stddef.h>

typedef struct DFState DFState;

/// Loads a DeepFilterNet model (tar.gz) and builds a processing state.
/// atten_lim: attenuation limit in dB (sign is ignored internally, .abs() is applied);
///            100.0 matches libDF's own RuntimeParams::default() (effectively unlimited).
/// log_level: e.g. "error"; pass NULL to disable internal logging.
DFState *df_create(const char *path, float atten_lim, const char *log_level);

/// Frame size (hop size), in samples at 48kHz, expected by df_process_frame.
size_t df_get_frame_length(DFState *st);

/// Processes exactly df_get_frame_length() samples from `input` into `output`.
/// Returns the local SNR (dB) of the processed frame.
float df_process_frame(DFState *st, float *input, float *output);

void df_free(DFState *model);

#endif
