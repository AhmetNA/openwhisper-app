"""48 kHz mono microphone capture and speech-preserving input normalization.

The sounddevice import is intentionally lazy. Importing the package and running its
unit tests therefore does not require an audio device or PortAudio to be installed.
"""

from __future__ import annotations

from dataclasses import dataclass
import queue
import threading
from typing import Iterator

import numpy as np


def _db_to_linear(db: float) -> float:
    return float(10.0 ** (db / 20.0))


@dataclass(frozen=True)
class AudioCaptureConfig:
    """Capture contract for the preprocessing pipeline."""

    sample_rate: int = 48_000
    channels: int = 1
    block_duration_ms: int = 500
    dtype: str = "float32"
    device: int | str | None = None
    max_queue_chunks: int = 8

    @property
    def blocksize(self) -> int:
        return self.sample_rate * self.block_duration_ms // 1_000

    def __post_init__(self) -> None:
        if self.sample_rate != 48_000:
            raise ValueError("Audio ingestion must capture at exactly 48 kHz")
        if self.channels != 1:
            raise ValueError("Audio ingestion must capture mono audio")
        if self.block_duration_ms <= 0 or self.blocksize <= 0:
            raise ValueError("block_duration_ms must produce a positive blocksize")
        if self.dtype != "float32":
            raise ValueError("Audio ingestion emits float32 PCM only")


class PeakRMSNormalizer:
    """Raise weak, finite mono chunks toward a -6 dBFS peak without clipping.

    Gain is never applied to digital silence and is capped to avoid turning a quiet
    room/noise floor into an unexpectedly loud signal. The RMS target participates
    in the decision so a single click does not define gain for an otherwise weak
    speech chunk.
    """

    def __init__(
        self,
        target_peak_dbfs: float = -6.0,
        target_rms_dbfs: float = -24.0,
        max_gain_db: float = 18.0,
        silence_rms_dbfs: float = -60.0,
    ) -> None:
        self.target_peak = _db_to_linear(target_peak_dbfs)
        self.target_rms = _db_to_linear(target_rms_dbfs)
        self.max_gain = _db_to_linear(max_gain_db)
        self.silence_rms = _db_to_linear(silence_rms_dbfs)

    def normalize(self, samples: np.ndarray) -> np.ndarray:
        audio = np.asarray(samples, dtype=np.float32)
        if audio.ndim != 1:
            raise ValueError("Audio normalizer expects a one-dimensional mono array")
        if not np.isfinite(audio).all():
            raise ValueError("Audio array contains NaN or infinite values")
        if audio.size == 0:
            return audio.copy()

        peak = float(np.max(np.abs(audio)))
        rms = float(np.sqrt(np.mean(np.square(audio), dtype=np.float64)))
        if peak == 0.0 or rms < self.silence_rms:
            return audio.copy()

        # Peak drives the -6 dBFS contract; RMS avoids a weak chunk being left
        # unnecessarily quiet when its peak is a short transient.
        peak_gain = self.target_peak / peak
        rms_gain = self.target_rms / rms
        gain = min(self.max_gain, max(1.0, peak_gain, rms_gain))
        normalized = audio * np.float32(gain)
        return np.clip(normalized, -0.999, 0.999).astype(np.float32, copy=False)


class AudioIngestor:
    """Yield normalized 500 ms blocks from a sounddevice input stream.

    The callback copies data before returning, keeping the PortAudio callback free
    of model/DSP work. If the consumer is slower than the bounded queue, the oldest
    block is discarded and an overrun counter is incremented.
    """

    def __init__(
        self,
        config: AudioCaptureConfig | None = None,
        normalizer: PeakRMSNormalizer | None = None,
    ) -> None:
        self.config = config or AudioCaptureConfig()
        self.normalizer = normalizer or PeakRMSNormalizer()
        self.overrun_count = 0

    def chunks(self, stop_event: threading.Event | None = None) -> Iterator[np.ndarray]:
        try:
            import sounddevice as sd
        except ImportError as exc:
            raise RuntimeError(
                "Audio capture requires sounddevice; install requirements-audio.txt"
            ) from exc

        events = stop_event or threading.Event()
        blocks: queue.Queue[np.ndarray | BaseException | None] = queue.Queue(
            maxsize=self.config.max_queue_chunks
        )

        def callback(indata: np.ndarray, frames: int, _time: object, status: object) -> None:
            del frames, _time
            if status:
                # Keep capture alive; sounddevice reports the status object to the
                # caller through the queue only when it is a hard callback failure.
                if getattr(status, "input_overflow", False):
                    self.overrun_count += 1
            try:
                block = np.asarray(indata[:, 0], dtype=np.float32).copy()
                normalized = self.normalizer.normalize(block)
                blocks.put_nowait(normalized)
            except queue.Full:
                self.overrun_count += 1
                try:
                    blocks.get_nowait()
                except queue.Empty:
                    pass
                blocks.put_nowait(normalized)
            except BaseException as exc:  # surface callback failures to the consumer
                try:
                    blocks.put_nowait(exc)
                except queue.Full:
                    pass

        with sd.InputStream(
            samplerate=self.config.sample_rate,
            blocksize=self.config.blocksize,
            channels=self.config.channels,
            dtype=self.config.dtype,
            device=self.config.device,
            callback=callback,
        ):
            while not events.is_set():
                item = blocks.get()
                if item is None:
                    return
                if isinstance(item, BaseException):
                    raise RuntimeError("Audio callback failed") from item
                yield item

