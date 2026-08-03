"""Silero ONNX VAD gate for cleaned 48 kHz microphone chunks."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Protocol

import numpy as np

from .output_validator import resample_audio


class SpeechScorer(Protocol):
    def score(self, samples_16k: np.ndarray) -> float:
        """Return speech probability in [0, 1]."""


@dataclass(frozen=True)
class SpeechGateResult:
    samples: np.ndarray
    speech_probability: float
    speech_present: bool


class SileroVADGate:
    """Gate 48 kHz chunks using a Silero ONNX Runtime scorer at 16 kHz."""

    def __init__(
        self,
        model_path: str | None = None,
        threshold: float = 0.5,
        scorer: SpeechScorer | Callable[[np.ndarray], float] | None = None,
    ) -> None:
        if not 0.0 <= threshold <= 1.0:
            raise ValueError("VAD threshold must be between 0 and 1")
        self.model_path = model_path
        self.threshold = threshold
        self._scorer = scorer

    def gate(self, samples: np.ndarray) -> SpeechGateResult:
        audio = np.asarray(samples, dtype=np.float32)
        if audio.ndim != 1:
            raise ValueError("Silero VAD gate expects mono audio")
        if not np.isfinite(audio).all():
            raise ValueError("Audio array contains NaN or infinite values")

        audio_16k = resample_audio(audio, 48_000, 16_000)
        scorer = self._scorer or self._load_scorer()
        if callable(scorer) and not hasattr(scorer, "score"):
            probability = float(scorer(audio_16k))
        else:
            probability = float(scorer.score(audio_16k))  # type: ignore[union-attr]
        if not np.isfinite(probability):
            raise ValueError("Silero VAD returned NaN or infinite probability")
        probability = float(np.clip(probability, 0.0, 1.0))
        speech_present = probability >= self.threshold
        output = audio.copy() if speech_present else np.zeros_like(audio)
        return SpeechGateResult(output, probability, speech_present)

    def _load_scorer(self) -> SpeechScorer:
        if not self.model_path:
            raise RuntimeError(
                "Silero ONNX VAD requires model_path or an injected scorer"
            )
        self._scorer = _SileroONNXScorer(self.model_path)
        return self._scorer


class _SileroONNXScorer:
    """Small adapter for the Silero ONNX model input/state contract."""

    def __init__(self, model_path: str) -> None:
        try:
            import onnxruntime as ort
        except ImportError as exc:
            raise RuntimeError(
                "Silero ONNX VAD requires onnxruntime; install requirements-audio.txt"
            ) from exc
        self.session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        self.inputs = {item.name: item for item in self.session.get_inputs()}
        self.state = self._initial_state()

    def _initial_state(self) -> np.ndarray:
        state_input = self.inputs.get("state")
        if state_input is None or not isinstance(state_input.shape, list):
            return np.zeros((2, 1, 128), dtype=np.float32)
        shape = [1 if value is None or isinstance(value, str) else int(value) for value in state_input.shape]
        return np.zeros(shape, dtype=np.float32)

    def score(self, samples_16k: np.ndarray) -> float:
        audio = np.asarray(samples_16k, dtype=np.float32).reshape(-1)
        frame_size = 512  # Silero's standard 16 kHz inference frame (32 ms).
        probabilities: list[float] = []
        for start in range(0, audio.size, frame_size):
            frame = audio[start : start + frame_size]
            if frame.size < frame_size:
                frame = np.pad(frame, (0, frame_size - frame.size))
            probabilities.append(self._score_frame(frame))
        return max(probabilities, default=0.0)

    def _score_frame(self, frame: np.ndarray) -> float:
        audio = np.asarray(frame, dtype=np.float32).reshape(1, -1)
        feed: dict[str, Any] = {}
        for name, input_meta in self.inputs.items():
            lower = name.lower()
            if lower == "input" or "audio" in lower:
                feed[name] = audio
            elif lower == "state":
                feed[name] = self.state
            elif lower in {"sr", "sampling_rate", "sample_rate"}:
                feed[name] = np.asarray(16_000, dtype=np.int64)

        outputs = self.session.run(None, feed)
        if len(outputs) > 1 and outputs[1].shape == self.state.shape:
            self.state = outputs[1].astype(np.float32, copy=False)
        return float(np.asarray(outputs[0]).reshape(-1)[0])
