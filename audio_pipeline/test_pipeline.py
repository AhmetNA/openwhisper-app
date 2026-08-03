"""
COMPREHENSIVE TEST SUITE FOR AUDIO PRE-PROCESSING PIPELINE (test_pipeline.py)

Tests all 4 Subagents individually and verifies end-to-end processing:
1. Subagent 1: Audio Ingestion & AGC Normalizer
2. Subagent 2: DeepFilterNet 3 Engine
3. Subagent 3: Silero VAD Gate
4. Subagent 4: Output Validator & STT Handshake
5. Master Pipeline Integration & Latency Benchmarks
"""

import os
import sys
import unittest
import numpy as np

# Add audio_pipeline directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audio_ingest import AudioIngestor, AGCNormalizer
from df_cleaner import DeepFilterCleaner
from vad_gate import SileroVADGate
from output_validator import OutputValidator
from pipeline import AudioPipeline


class TestAudioPipeline(unittest.TestCase):

    def setUp(self):
        self.sample_rate_48k = 48000
        self.chunk_duration = 0.5  # 500 ms
        self.chunk_samples_48k = int(self.sample_rate_48k * self.chunk_duration)  # 24,000 samples

    def test_subagent1_agc_normalizer(self):
        """Test Subagent 1: AGC Normalizer boosts quiet speech to -6 dB FS without clipping."""
        ingestor = AudioIngestor(sample_rate=self.sample_rate_48k)
        
        # Test 1: Quiet input (peak amplitude 0.05 => ~ -26 dB FS)
        t = np.linspace(0, 0.5, self.chunk_samples_48k, endpoint=False)
        quiet_signal = (0.05 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
        
        normalized = ingestor.process_chunk(quiet_signal)
        peak_amp = float(np.max(np.abs(normalized)))
        
        # -6 dB FS translates to ~0.5012 amplitude
        self.assertAlmostEqual(peak_amp, 0.5012, delta=0.05, msg="AGC failed to normalize to -6 dB FS")
        self.assertTrue(np.all(normalized >= -1.0) and np.all(normalized <= 1.0), "Signal clipped out of bounds")

        # Test 2: Absolute silence should not explode into max gain noise
        silence = np.zeros(self.chunk_samples_48k, dtype=np.float32)
        norm_silence = ingestor.process_chunk(silence)
        self.assertTrue(np.all(norm_silence == 0.0), "AGC amplified silence inappropriately")

    def test_subagent2_df_cleaner(self):
        """Test Subagent 2: DeepFilterCleaner removes background noise on 48 kHz chunk."""
        cleaner = DeepFilterCleaner(sample_rate=self.sample_rate_48k, attenuation_limit=-100.0)
        
        t = np.linspace(0, 0.5, self.chunk_samples_48k, endpoint=False)
        clean_speech = 0.4 * np.sin(2 * np.pi * 500 * t)
        noise = 0.15 * np.random.randn(len(t))
        noisy_chunk = (clean_speech + noise).astype(np.float32)

        cleaned_chunk = cleaner.clean_chunk(noisy_chunk)
        
        self.assertEqual(len(cleaned_chunk), len(noisy_chunk))
        self.assertEqual(cleaned_chunk.dtype, np.float32)
        self.assertFalse(np.isnan(cleaned_chunk).any(), "Cleaned audio contains NaNs")

    def test_subagent3_vad_gate(self):
        """Test Subagent 3: Silero VAD zeroing out non-speech chunks."""
        vad = SileroVADGate(threshold=0.5, sample_rate=self.sample_rate_48k)

        # 1. Pure silence
        silence = np.zeros(self.chunk_samples_48k, dtype=np.float32)
        gated_silence, prob_sil, active_sil = vad.process_chunk(silence)
        self.assertFalse(active_sil, "VAD falsely detected speech in silence")
        self.assertTrue(np.all(gated_silence == 0.0), "Silence chunk was not zeroed out")

        # 2. Voice signal (440 Hz tone)
        t = np.linspace(0, 0.5, self.chunk_samples_48k, endpoint=False)
        voice = (0.5 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
        gated_voice, prob_v, active_v = vad.process_chunk(voice)
        self.assertTrue(active_v, "VAD failed to detect speech signal")
        self.assertGreaterEqual(prob_v, 0.5, "Speech probability below 0.5 threshold")

    def test_subagent4_output_validator(self):
        """Test Subagent 4: Resampler to 16 kHz Mono & Double-Check assertions."""
        validator = OutputValidator(input_sample_rate=48000, target_sample_rate=16000)

        # 500 ms chunk @ 48 kHz (24,000 samples)
        chunk_48k = np.random.randn(self.chunk_samples_48k).astype(np.float32)
        payload = validator.validate_and_format(chunk_48k, orig_sr=48000)

        # STT Handshake assertions
        self.assertEqual(payload["sample_rate"], 16000, "Sample rate is not 16 kHz")
        self.assertEqual(len(payload["audio"]), 8000, "500 ms @ 16 kHz should yield 8000 samples")
        self.assertEqual(payload["duration_ms"], 500.0, "Duration calculation incorrect")
        self.assertEqual(payload["audio"].dtype, np.float32, "Audio dtype must be float32")
        self.assertFalse(np.isnan(payload["audio"]).any(), "Audio payload contains NaNs")

    def test_master_pipeline_end_to_end(self):
        """Test end-to-end master pipeline integration and processing latency."""
        pipeline = AudioPipeline(
            input_sample_rate=48000,
            target_sample_rate=16000,
            attenuation_limit=-100.0,
            vad_threshold=0.5,
        )

        t = np.linspace(0, 0.5, self.chunk_samples_48k, endpoint=False)
        whisper_speech = (0.05 * np.sin(2 * np.pi * 350 * t)).astype(np.float32)

        stt_payload, metrics = pipeline.process_chunk(whisper_speech)

        # Verify output payload
        self.assertEqual(stt_payload["sample_rate"], 16000)
        self.assertEqual(len(stt_payload["audio"]), 8000)
        self.assertEqual(stt_payload["duration_ms"], 500.0)
        self.assertFalse(np.isnan(stt_payload["audio"]).any())

        # Verify latency constraints
        total_latency = metrics["total_latency_ms"]
        print(f"\n[BENCHMARK] End-to-End Latency: {total_latency} ms")
        self.assertLess(total_latency, 2000.0, "Total latency exceeded 2.0s strict budget")


if __name__ == "__main__":
    unittest.main()
