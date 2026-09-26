#ifndef OPENWHISPER_WEBRTC_AEC_H
#define OPENWHISPER_WEBRTC_AEC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OWAEC3Handle OWAEC3Handle;

/// Creates a 16 kHz, mono WebRTC AEC3 processor that exports its linear output.
OWAEC3Handle *ow_aec3_create(void);

/// Processes exactly one 10 ms frame (160 float samples). Returns 0 on success.
int ow_aec3_process(
    OWAEC3Handle *handle,
    const float *microphone,
    const float *reference,
    float *linear_output,
    size_t sample_count
);

void ow_aec3_destroy(OWAEC3Handle *handle);

#ifdef __cplusplus
}
#endif

#endif
