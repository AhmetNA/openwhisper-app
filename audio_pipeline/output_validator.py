"""High-quality 48 kHz -> 16 kHz conversion and Whisper handshake validation."""

from __future__ import annotations

from typing import TypedDict

import numpy as np


class AudioPayload(TypedDict):
    audio: np.ndarray
    sample_rate: int
    duration_ms: int


def resample_audio(samples: np.ndarray, input_rate: int, output_rate: int) -> np.ndarray:
    """Resample mono float32 audio, preferring SoXR HQ and using SciPy as a fallback."""

    audio = np.asarray(samples, dtype=np.float32)
    if audio.ndim != 1:
        raise ValueError("Resampling expects a one-dimensional mono array")
    if not np.isfinite(audio).all():
        raise ValueError("Audio array contains NaN or infinite values")
    if input_rate == output_rate:
        return audio.copy()

    try:
        import soxr
    except ImportError:
        try:
            from scipy.signal import resample_poly
        except ImportError as exc:
            raise RuntimeError("Install soxr for production audio resampling") from exc
        from math import gcd

        divisor = gcd(input_rate, output_rate)
        result = resample_poly(
            audio,
            output_rate // divisor,
            input_rate // divisor,
        )
    else:
        result = soxr.resample(audio, input_rate, output_rate, quality="HQ")

    expected = round(audio.size * output_rate / input_rate)
    result = np.asarray(result, dtype=np.float32).reshape(-1)
    # soxr/scipy can differ by one sample at a boundary. Whisper only needs a
    # deterministic duration, so trim/pad the converter output to the exact ratio.
    if result.size > expected:
        result = result[:expected]
    elif result.size < expected:
        result = np.pad(result, (0, expected - result.size))
    return result.astype(np.float32, copy=False)


class OutputValidator:
    """Produce a validated Whisper-compatible payload."""

    sample_rate = 16_000

    def __init__(self, input_sample_rate: int = 48_000) -> None:
        self.input_sample_rate = input_sample_rate

    def payload(self, chunk: np.ndarray, channels: int = 1) -> AudioPayload:
        audio = np.asarray(chunk)
        if audio.ndim == 2:
            if audio.shape[1] != 1:
                raise AssertionError("ERROR: Audio must be single channel (Mono)!")
            audio = audio[:, 0]
        elif audio.ndim != 1:
            raise AssertionError("ERROR: Audio must be single channel (Mono)!")
        if channels != 1:
            raise AssertionError("ERROR: Audio must be single channel (Mono)!")
        if np.isnan(audio).any():
            raise AssertionError("ERROR: Audio array contains NaN values!")
        if not np.isfinite(audio).all():
            raise AssertionError("ERROR: Audio array contains infinite values!")

        audio = np.asarray(audio, dtype=np.float32)
        if self.input_sample_rate != self.sample_rate:
            audio = resample_audio(audio, self.input_sample_rate, self.sample_rate)
        self.validate(audio, sample_rate=self.sample_rate, channels=1)
        return {
            "audio": audio,
            "sample_rate": self.sample_rate,
            "duration_ms": round(audio.size * 1_000 / self.sample_rate),
        }

    @staticmethod
    def validate(audio: np.ndarray, sample_rate: int, channels: int) -> None:
        if sample_rate != 16_000:
            raise AssertionError(
                "ERROR: Audio sample rate must be exactly 16kHz for Whisper/Large-Turbo!"
            )
        if channels != 1:
            raise AssertionError("ERROR: Audio must be single channel (Mono)!")
        if np.asarray(audio).dtype not in (np.dtype(np.float32), np.dtype(np.int16)):
            raise AssertionError("ERROR: Invalid audio data type!")
        if np.isnan(audio).any():
            raise AssertionError("ERROR: Audio array contains NaN values!")
        if not np.isfinite(audio).all():
            raise AssertionError("ERROR: Audio array contains infinite values!")


def make_whisper_payload(chunk: np.ndarray, input_sample_rate: int = 48_000) -> AudioPayload:
    return OutputValidator(input_sample_rate=input_sample_rate).payload(chunk)
