"""
SUBAGENT 1: Audio Ingestion & Pre-DSP Module (audio_ingest.py)

Responsibilities:
1. Capture/Ingest 48 kHz Mono PCM audio chunks.
2. Apply Peak and RMS Automatic Gain Control (AGC) Normalization:
   - Target Peak Gain: -6 dB FS (0.5012 amplitude) for weak/quiet whisper inputs.
   - Intelligent Noise Floor Guard: Avoid amplifying pure background silence/noise.
   - Clipping Prevention & Headroom: Soft clipping guard to keep float32 values within [-1.0, 1.0].
"""

import numpy as np
import logging
from typing import Optional, Union, Tuple

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("AudioIngestor")

# Constants
DEFAULT_SAMPLE_RATE = 48000
TARGET_PEAK_DBFS = -6.0  # Target peak level in dB FS
TARGET_PEAK_AMP = 10.0 ** (TARGET_PEAK_DBFS / 20.0)  # ~0.501187
MIN_SILENCE_THRESHOLD = 1e-4  # Absolute RMS floor to prevent amplifying background silence
MAX_GAIN_FACTOR = 10.0  # Max gain multiplier (+20 dB) for safety


class AGCNormalizer:
    """
    Automatic Gain Control & Peak/RMS Normalizer.
    Normalizes weak audio inputs to target -6 dB FS while guarding against noise amplification and clipping.
    """

    def __init__(
        self,
        target_peak_dbfs: float = TARGET_PEAK_DBFS,
        min_silence_threshold: float = MIN_SILENCE_THRESHOLD,
        max_gain_factor: float = MAX_GAIN_FACTOR,
    ):
        self.target_peak_dbfs = target_peak_dbfs
        self.target_peak_amp = 10.0 ** (target_peak_dbfs / 20.0)
        self.min_silence_threshold = min_silence_threshold
        self.max_gain_factor = max_gain_factor

    def normalize(self, chunk: np.ndarray) -> np.ndarray:
        """
        Normalize audio chunk peak to -6 dB FS if input contains signal above silence threshold.
        
        Args:
            chunk: Input audio chunk (1D numpy array, float32, range [-1.0, 1.0])
        
        Returns:
            Normalized 1D numpy float32 array.
        """
        if chunk is None or len(chunk) == 0:
            return np.array([], dtype=np.float32)

        # Ensure float32 array
        audio = np.asarray(chunk, dtype=np.float32)
        
        # Calculate current Peak and RMS
        current_peak = float(np.max(np.abs(audio)))
        current_rms = float(np.sqrt(np.mean(audio ** 2)))

        # Guard against empty/silent audio
        if current_peak < self.min_silence_threshold or current_rms < self.min_silence_threshold:
            # Below noise floor threshold: do not boost gain
            return np.clip(audio, -1.0, 1.0)

        # Calculate required gain factor to reach target peak (-6 dB FS)
        gain_factor = self.target_peak_amp / current_peak
        
        # Cap max gain factor to prevent over-amplifying low-level noise
        gain_factor = min(gain_factor, self.max_gain_factor)

        # Apply gain
        normalized_audio = audio * gain_factor

        # Soft clip / hard clip guard to strictly enforce [-1.0, 1.0] bounds
        normalized_audio = np.clip(normalized_audio, -1.0, 1.0)

        return normalized_audio.astype(np.float32)


class AudioIngestor:
    """
    Ingests 48 kHz Mono audio chunks and applies AGC pre-processing.
    """

    def __init__(self, sample_rate: int = DEFAULT_SAMPLE_RATE):
        self.sample_rate = sample_rate
        self.normalizer = AGCNormalizer()

    def process_chunk(self, chunk: np.ndarray) -> np.ndarray:
        """
        Ingest a raw 48 kHz audio chunk, convert stereo to mono if necessary, and apply AGC normalization.
        """
        if chunk is None or len(chunk) == 0:
            return np.array([], dtype=np.float32)

        audio = np.asarray(chunk, dtype=np.float32)

        # Handle stereo -> mono downmix if necessary
        if audio.ndim == 2:
            if audio.shape[1] > 1:
                audio = np.mean(audio, axis=1)
            else:
                audio = audio.squeeze(axis=1)

        # Normalize gain
        cleaned_chunk = self.normalizer.normalize(audio)
        return cleaned_chunk


if __name__ == "__main__":
    # Self-test
    ingestor = AudioIngestor(sample_rate=48000)
    # Simulate low volume 48kHz audio (whisper scenario)
    t = np.linspace(0, 0.5, 24000, endpoint=False)
    whisper_signal = (0.05 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    
    result = ingestor.process_chunk(whisper_signal)
    print(f"Original Peak: {np.max(np.abs(whisper_signal)):.4f}")
    print(f"Normalized Peak: {np.max(np.abs(result)):.4f} (Target: ~0.5012)")
    assert np.isclose(np.max(np.abs(result)), 0.5012, atol=0.05)
    print("SUBAGENT 1 Ingest & AGC: SUCCESS!")
