"""
SUBAGENT 4: Formatting & Double-Check Assertion Module (output_validator.py)

Responsibilities:
1. Resampling: Convert 48 kHz clean audio chunk to 16,000 Hz Mono using high-quality soxr resampling.
2. Double-Check Assertion Steps (STT Handshake):
   - assert sample_rate == 16000
   - assert channels == 1
   - assert dtype in [np.float32, np.int16]
   - assert not np.isnan(chunk).any()
3. Payload Formatting:
   {"audio": np.ndarray, "sample_rate": 16000, "duration_ms": float}
"""

import numpy as np
import logging
from typing import Dict, Any

logger = logging.getLogger("OutputValidator")

TARGET_SAMPLE_RATE = 16000
TARGET_CHANNELS = 1


class OutputValidator:
    """
    Resamples audio to 16 kHz Mono and verifies STT ingestion compatibility.
    """

    def __init__(self, input_sample_rate: int = 48000, target_sample_rate: int = TARGET_SAMPLE_RATE):
        self.input_sample_rate = input_sample_rate
        self.target_sample_rate = target_sample_rate
        self._resampler_type = "soxr"

        # Pre-check soxr availability
        try:
            import soxr
            self._resampler_type = "soxr"
        except ImportError:
            self._resampler_type = "scipy"
            logger.info("soxr package not found; using scipy.signal.resample_poly for 48kHz -> 16kHz conversion.")

    def resample(self, chunk: np.ndarray, orig_sr: int = 48000) -> np.ndarray:
        """
        Resample input audio from 48 kHz to 16,000 Hz Mono.
        """
        if chunk is None or len(chunk) == 0:
            return np.array([], dtype=np.float32)

        audio = np.asarray(chunk, dtype=np.float32)

        # Force Mono if 2D array
        if audio.ndim == 2:
            if audio.shape[1] > 1:
                audio = np.mean(audio, axis=1)
            else:
                audio = audio.squeeze(axis=1)

        if orig_sr == self.target_sample_rate:
            return audio.astype(np.float32)

        if self._resampler_type == "soxr":
            try:
                import soxr
                resampled = soxr.resample(audio, orig_sr, self.target_sample_rate, quality="VHQ")
                return resampled.astype(np.float32)
            except Exception as e:
                logger.warning(f"soxr resample failed ({e}); falling back to scipy.")

        # Scipy polyphase resampler fallback (48000 -> 16000 is exactly 1:3 downsampling ratio)
        from scipy import signal
        gcd = np.gcd(orig_sr, self.target_sample_rate)
        up = self.target_sample_rate // gcd  # e.g., 16000 // 16000 = 1
        down = orig_sr // gcd                # e.g., 48000 // 16000 = 3
        
        resampled = signal.resample_poly(audio, up, down)
        return resampled.astype(np.float32)

    def validate_and_format(self, chunk: np.ndarray, orig_sr: int = 48000) -> Dict[str, Any]:
        """
        Resample chunk, execute double-check assertions, and build payload dictionary for Whisper / STT.

        Args:
            chunk: Input audio chunk (48 kHz).
            orig_sr: Original sample rate (default 48000 Hz).

        Returns:
            Dictionary: {"audio": np.ndarray, "sample_rate": 16000, "duration_ms": float}
        """
        # Step 1: High Quality Resampling to 16 kHz Mono
        resampled_audio = self.resample(chunk, orig_sr=orig_sr)

        # Channel calculation
        channels = 1 if resampled_audio.ndim == 1 else resampled_audio.shape[1]
        sample_rate = self.target_sample_rate
        dtype = resampled_audio.dtype

        # Step 2: Double-Check Assertion Steps (STT Handshake)
        assert sample_rate == 16000, f"ERROR: Audio sample rate must be exactly 16kHz for Whisper/Large-Turbo! Got {sample_rate}"
        assert channels == 1, f"ERROR: Audio must be single channel (Mono)! Got {channels}"
        assert dtype in [np.float32, np.int16], f"ERROR: Invalid audio data type! Got {dtype}"
        assert not np.isnan(resampled_audio).any(), "ERROR: Audio array contains NaN values!"
        assert not np.isinf(resampled_audio).any(), "ERROR: Audio array contains Inf values!"

        # Step 3: Compute Duration
        duration_ms = (len(resampled_audio) / float(self.target_sample_rate)) * 1000.0

        # Step 4: Construct verified payload dictionary
        payload = {
            "audio": resampled_audio,
            "sample_rate": sample_rate,
            "duration_ms": round(duration_ms, 2),
        }

        return payload


if __name__ == "__main__":
    validator = OutputValidator(input_sample_rate=48000, target_sample_rate=16000)
    
    # 500 ms chunk @ 48 kHz = 24,000 samples
    chunk_48k = np.random.randn(24000).astype(np.float32)
    payload = validator.validate_and_format(chunk_48k, orig_sr=48000)

    print(f"Sample Rate: {payload['sample_rate']} Hz")
    print(f"Audio Length: {len(payload['audio'])} samples (Target: 8,000 samples @ 16kHz)")
    print(f"Duration: {payload['duration_ms']} ms")
    print(f"Dtype: {payload['audio'].dtype}")

    assert payload["sample_rate"] == 16000
    assert len(payload["audio"]) == 8000
    assert payload["duration_ms"] == 500.0
    assert not np.isnan(payload["audio"]).any()

    print("SUBAGENT 4 OutputValidator: SUCCESS!")
