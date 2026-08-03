import unittest

import numpy as np

from audio_pipeline.audio_ingest import AudioCaptureConfig, PeakRMSNormalizer
from audio_pipeline.output_validator import OutputValidator, resample_audio
from audio_pipeline.pipeline import AudioPreprocessingPipeline
from audio_pipeline.vad_gate import SpeechGateResult, SileroVADGate


class _IdentityCleaner:
    def clean_chunk(self, samples):
        return samples.copy()


class _FixedGate:
    def __init__(self, probability):
        self.probability = probability

    def gate(self, samples):
        accepted = self.probability >= 0.5
        output = samples.copy() if accepted else np.zeros_like(samples)
        return SpeechGateResult(output, self.probability, accepted)


class AudioPipelineTests(unittest.TestCase):
    def test_capture_contract_is_48khz_mono_500ms(self):
        config = AudioCaptureConfig()
        self.assertEqual(config.sample_rate, 48_000)
        self.assertEqual(config.channels, 1)
        self.assertEqual(config.blocksize, 24_000)

    def test_normalizer_raises_weak_audio_toward_minus_six_dbfs(self):
        audio = np.full(400, 0.1, dtype=np.float32)
        normalized = PeakRMSNormalizer().normalize(audio)
        self.assertAlmostEqual(float(np.max(np.abs(normalized))), 10 ** (-6 / 20), places=3)
        self.assertEqual(normalized.dtype, np.float32)

    def test_silero_gate_zeros_below_threshold(self):
        audio = np.ones(24_000, dtype=np.float32)
        result = SileroVADGate(scorer=lambda _audio: 0.49).gate(audio)
        self.assertFalse(result.speech_present)
        self.assertTrue(np.array_equal(result.samples, np.zeros_like(audio)))

    def test_silero_gate_passes_at_threshold(self):
        audio = np.ones(24_000, dtype=np.float32)
        result = SileroVADGate(scorer=lambda _audio: 0.5).gate(audio)
        self.assertTrue(result.speech_present)
        self.assertTrue(np.array_equal(result.samples, audio))

    def test_output_payload_is_exactly_16k_mono_float32(self):
        audio = np.zeros(24_000, dtype=np.float32)
        payload = OutputValidator().payload(audio)
        self.assertEqual(payload["sample_rate"], 16_000)
        self.assertEqual(payload["audio"].shape, (8_000,))
        self.assertEqual(payload["audio"].dtype, np.float32)
        self.assertEqual(payload["duration_ms"], 500)

    def test_nan_rejected_with_handshake_message(self):
        with self.assertRaisesRegex(AssertionError, "Audio array contains NaN"):
            OutputValidator().payload(np.array([np.nan], dtype=np.float32))

    def test_pipeline_zeroes_vad_rejected_chunk_and_validates_output(self):
        audio = np.ones(24_000, dtype=np.float32)
        pipeline = AudioPreprocessingPipeline(_IdentityCleaner(), _FixedGate(0.1))
        payload = pipeline.process_chunk(audio)
        self.assertTrue(np.array_equal(payload["audio"], np.zeros(8_000, dtype=np.float32)))
        self.assertEqual(payload["sample_rate"], 16_000)

    def test_resampler_produces_expected_ratio(self):
        audio = np.zeros(48_000, dtype=np.float32)
        self.assertEqual(resample_audio(audio, 48_000, 16_000).size, 16_000)


if __name__ == "__main__":
    unittest.main()
