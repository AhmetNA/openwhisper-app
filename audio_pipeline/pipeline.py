"""Composable end-to-end preprocessing pipeline."""

from __future__ import annotations

from typing import Iterable, Iterator, Protocol

import numpy as np

from .df_cleaner import DeepFilterNet3Cleaner
from .output_validator import AudioPayload, OutputValidator
from .vad_gate import SileroVADGate, SpeechGateResult


class Cleaner(Protocol):
    def clean_chunk(self, samples: np.ndarray) -> np.ndarray: ...


class Gate(Protocol):
    def gate(self, samples: np.ndarray) -> SpeechGateResult: ...


class AudioPreprocessingPipeline:
    """Normalize -> DFN3 -> Silero gate -> 16 kHz payload.

    Concrete model objects are injected so imports/tests do not download models and
    so the app can decide when to pay model initialization cost.
    """

    input_sample_rate = 48_000
    chunk_samples = 24_000

    def __init__(
        self,
        cleaner: Cleaner | None = None,
        gate: Gate | None = None,
        validator: OutputValidator | None = None,
    ) -> None:
        self.cleaner = cleaner or DeepFilterNet3Cleaner()
        self.gate = gate or SileroVADGate()
        self.validator = validator or OutputValidator()

    def process_chunk(self, normalized_chunk: np.ndarray) -> AudioPayload:
        audio = np.asarray(normalized_chunk, dtype=np.float32)
        if audio.ndim != 1 or not np.isfinite(audio).all():
            raise ValueError("Pipeline input must be finite mono float32 audio")
        if audio.size != self.chunk_samples:
            raise ValueError(
                f"Pipeline expects one 500 ms/24,000-sample chunk, got {audio.size}"
            )
        cleaned = self.cleaner.clean_chunk(audio)
        gated = self.gate.gate(cleaned)
        return self.validator.payload(gated.samples, channels=1)

    def process_stream(self, chunks: Iterable[np.ndarray]) -> Iterator[AudioPayload]:
        for chunk in chunks:
            yield self.process_chunk(chunk)
