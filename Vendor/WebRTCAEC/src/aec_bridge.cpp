#include "webrtc_aec.h"

#include <algorithm>
#include <array>
#include <memory>
#include <new>
#include <optional>

#include "api/audio/audio_processing.h"
#include "api/audio/echo_control.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"

namespace {

constexpr size_t kFrameSamples = 160;

// AudioProcessing's built-in AEC3 factory does not safely expose the linear output in v2.1.
// Construct EchoCanceller3 ourselves with export_linear_aec_output enabled, matching the
// verified offline harness in tools/aec3-bench/aec3run.cpp.
class LinearAec3Factory final : public webrtc::EchoControlFactory {
 public:
  std::unique_ptr<webrtc::EchoControl> Create(
      int sample_rate_hz,
      int num_render_channels,
      int num_capture_channels) override {
    webrtc::EchoCanceller3Config config;
    config.filter.export_linear_aec_output = true;
    return std::make_unique<webrtc::EchoCanceller3>(
        config,
        std::nullopt,
        sample_rate_hz,
        num_render_channels,
        num_capture_channels);
  }
};

}  // namespace

struct OWAEC3Handle {
  rtc::scoped_refptr<webrtc::AudioProcessing> processor;
};

OWAEC3Handle *ow_aec3_create(void) {
  auto processor = webrtc::AudioProcessingBuilder()
                       .SetEchoControlFactory(std::make_unique<LinearAec3Factory>())
                       .Create();
  if (!processor) {
    return nullptr;
  }

  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.export_linear_aec_output = true;
  processor->ApplyConfig(config);

  auto *handle = new (std::nothrow) OWAEC3Handle;
  if (!handle) {
    return nullptr;
  }
  handle->processor = std::move(processor);
  return handle;
}

int ow_aec3_process(
    OWAEC3Handle *handle,
    const float *microphone,
    const float *reference,
    float *linear_output,
    size_t sample_count) {
  if (!handle || !handle->processor || !microphone || !reference || !linear_output ||
      sample_count != kFrameSamples) {
    return -1;
  }

  webrtc::StreamConfig stream_config(16000, 1);
  const float *render_input[] = {reference};
  std::array<float, kFrameSamples> render_scratch{};
  float *render_output[] = {render_scratch.data()};
  if (handle->processor->ProcessReverseStream(
          render_input, stream_config, stream_config, render_output) != 0) {
    return -2;
  }

  handle->processor->set_stream_delay_ms(0);
  const float *capture_input[] = {microphone};
  std::array<float, kFrameSamples> capture_scratch{};
  float *capture_output[] = {capture_scratch.data()};
  if (handle->processor->ProcessStream(
          capture_input, stream_config, stream_config, capture_output) != 0) {
    return -3;
  }

  std::array<float, kFrameSamples> linear{};
  handle->processor->GetLinearAecOutput(
      rtc::ArrayView<std::array<float, kFrameSamples>>(&linear, 1));
  std::copy(linear.begin(), linear.end(), linear_output);
  return 0;
}

void ow_aec3_destroy(OWAEC3Handle *handle) {
  delete handle;
}
