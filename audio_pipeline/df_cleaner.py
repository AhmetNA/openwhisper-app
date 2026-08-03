"""DeepFilterNet 3 enhancement adapter for 48 kHz half-second chunks."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import numpy as np


class CleanerBackend(Protocol):
    def enhance(self, samples: np.ndarray, attenuation_limit: float) -> np.ndarray:
        """Enhance one mono 48 kHz chunk and return a mono float array."""


@dataclass(frozen=True)
class DeepFilterConfig:
    sample_rate: int = 48_000
    chunk_duration_ms: int = 500
    # DeepFilterNet's public argument is a positive magnitude. Keeping the
    # roadmap's -100 value here makes the requested max-erasure intent explicit;
    # the adapter passes abs() to atten_lim_db.
    attenuation_limit: float = -100.0
    model_name: str = "DeepFilterNet3"
    compensate_delay: bool = True

    @property
    def chunk_samples(self) -> int:
        return self.sample_rate * self.chunk_duration_ms // 1_000

    def __post_init__(self) -> None:
        if self.sample_rate != 48_000:
            raise ValueError("DeepFilterNet3 input must be 48 kHz")
        if self.chunk_duration_ms != 500:
            raise ValueError("The realtime cleaner contract uses 500 ms chunks")


class DeepFilterNet3Cleaner:
    """Lazy DeepFilterNet3 wrapper.

    DeepFilterNet's Python backend selects the available PyTorch device. On Apple
    Silicon this may be MPS, but the Python package does not prove Apple Neural
    Engine execution; callers must benchmark the installed runtime separately.
    """

    def __init__(
        self,
        config: DeepFilterConfig | None = None,
        backend: CleanerBackend | None = None,
    ) -> None:
        self.config = config or DeepFilterConfig()
        self._backend = backend

    def clean_chunk(self, samples: np.ndarray) -> np.ndarray:
        audio = np.asarray(samples, dtype=np.float32)
        if audio.ndim != 1:
            raise ValueError("DeepFilterNet3 cleaner expects mono audio")
        if audio.size != self.config.chunk_samples:
            raise ValueError(
                f"DeepFilterNet3 cleaner expects exactly {self.config.chunk_samples} "
                f"samples per 500 ms chunk, got {audio.size}"
            )
        if not np.isfinite(audio).all():
            raise ValueError("Audio array contains NaN or infinite values")
        if audio.size == 0:
            return audio.copy()
        backend = self._backend or self._load_backend()
        cleaned = np.asarray(
            backend.enhance(audio, abs(self.config.attenuation_limit)), dtype=np.float32
        ).reshape(-1)
        if cleaned.size != audio.size:
            raise ValueError(
                "DeepFilterNet3 backend changed chunk length; use compensate_delay=True"
            )
        if not np.isfinite(cleaned).all():
            raise ValueError("DeepFilterNet3 returned NaN or infinite values")
        return np.clip(cleaned, -1.0, 1.0).astype(np.float32, copy=False)

    def _load_backend(self) -> CleanerBackend:
        try:
            from df import enhance, init_df
        except ImportError as exc:
            raise RuntimeError(
                "DeepFilterNet3 requires deepfilternet and its libdf dependency"
            ) from exc

        model, state, _suffix, _epoch = init_df(
            self.config.model_name,
            log_file=None,
            config_allow_defaults=True,
        )
        self._backend = _DeepFilterPythonBackend(
            model=model,
            state=state,
            enhance_fn=enhance,
            compensate_delay=self.config.compensate_delay,
        )
        return self._backend


class _DeepFilterPythonBackend:
    def __init__(
        self,
        model: Any,
        state: Any,
        enhance_fn: Any,
        compensate_delay: bool,
    ) -> None:
        self.model = model
        self.state = state
        self.enhance_fn = enhance_fn
        self.compensate_delay = compensate_delay

    def enhance(self, samples: np.ndarray, attenuation_limit: float) -> np.ndarray:
        try:
            import torch
        except ImportError as exc:
            raise RuntimeError("DeepFilterNet3 requires PyTorch") from exc

        audio = torch.from_numpy(np.asarray(samples, dtype=np.float32)).unsqueeze(0)
        enhanced = self.enhance_fn(
            self.model,
            self.state,
            audio,
            pad=self.compensate_delay,
            atten_lim_db=attenuation_limit,
        )
        return enhanced.detach().cpu().numpy().reshape(-1)
