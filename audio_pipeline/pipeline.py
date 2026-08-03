"""
MASTER AUDIO PRE-PROCESSING PIPELINE (pipeline.py)

Architecture Flow:
[Mic / Audio Input @ 48kHz] 
        │
        ▼
[Subagent 1: Audio Ingestion & AGC Normalizer]  (audio_ingest.py)
        │
        ▼
[Subagent 2: DeepFilterNet 3 (Noise Clean @ 48kHz)]  (df_cleaner.py)
        │
        ▼
[Subagent 3: Silero VAD (Speech Gate @ 48kHz/16kHz)]  (vad_gate.py)
        │
        ▼
[Subagent 4: Resampler & Validator (16kHz Mono)]  (output_validator.py)
        │
        ▼
[ Downstream Whisper-Large-V3-Turbo STT Model ]
"""

import time
import numpy as np
import logging
from typing import Dict, Any, Generator, Optional, Tuple

from audio_ingest import AudioIngestor
from df_cleaner import DeepFilterCleaner
from vad_gate import SileroVADGate
from output_validator import OutputValidator

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("AudioPreprocessingPipeline")


class AudioPipeline:
    """
    Unified Audio Pre-Processing Pipeline targeting Whisper / Large-Turbo.
    """

    def __init__(
        self,
        input_sample_rate: int = 48000,
        target_sample_rate: int = 16000,
        attenuation_limit: float = -100.0,
        vad_threshold: float = 0.5,
    ):
        self.input_sample_rate = input_sample_rate
        self.target_sample_rate = target_sample_rate
        self.attenuation_limit = attenuation_limit
        self.vad_threshold = vad_threshold

        # Initialize Subagents
        logger.info("Initializing Subagent 1: Audio Ingestion & AGC Normalizer...")
        self.ingestor = AudioIngestor(sample_rate=input_sample_rate)

        logger.info(f"Initializing Subagent 2: DeepFilterNet 3 Engine (attenuation_limit={attenuation_limit} dB)...")
        self.df_cleaner = DeepFilterCleaner(
            sample_rate=input_sample_rate,
            attenuation_limit=attenuation_limit,
        )

        logger.info(f"Initializing Subagent 3: Silero VAD Gate (threshold={vad_threshold})...")
        self.vad_gate = SileroVADGate(
            threshold=vad_threshold,
            sample_rate=input_sample_rate,
        )

        logger.info(f"Initializing Subagent 4: Resampler & STT Output Validator (48kHz -> {target_sample_rate}Hz)...")
        self.validator = OutputValidator(
            input_sample_rate=input_sample_rate,
            target_sample_rate=target_sample_rate,
        )

        # Warm up pipeline engine to pre-cache JIT kernels and STFT plans
        logger.info("Warming up pipeline engine...")
        dummy_chunk = np.zeros(int(input_sample_rate * 0.1), dtype=np.float32)
        self.process_chunk(dummy_chunk, is_warmup=True)

        logger.info("Audio Pre-Processing Pipeline initialization complete.")

    def process_chunk(self, raw_chunk: np.ndarray, is_warmup: bool = False) -> Tuple[Dict[str, Any], Dict[str, float]]:
        """
        Process a single audio chunk through all 4 subagent pipeline stages.

        Args:
            raw_chunk: 1D numpy array of float32 audio samples @ 48 kHz.

        Returns:
            Tuple of:
            - STT Payload: {"audio": np.ndarray, "sample_rate": 16000, "duration_ms": float}
            - Processing Metrics: latency details (ms), speech probability, active flag.
        """
        t_start = time.perf_counter()

        # Stage 1: Audio Ingestion & AGC Normalizer (48 kHz)
        t1 = time.perf_counter()
        normalized_chunk = self.ingestor.process_chunk(raw_chunk)
        dur_stage1 = (time.perf_counter() - t1) * 1000.0

        # Stage 2: DeepFilterNet 3 Noise Suppression (48 kHz)
        t2 = time.perf_counter()
        cleaned_chunk = self.df_cleaner.clean_chunk(normalized_chunk)
        dur_stage2 = (time.perf_counter() - t2) * 1000.0

        # Stage 3: Silero VAD Gate (48 kHz)
        t3 = time.perf_counter()
        gated_chunk, speech_prob, is_speech_active = self.vad_gate.process_chunk(cleaned_chunk)
        dur_stage3 = (time.perf_counter() - t3) * 1000.0

        # Stage 4: Resampling to 16 kHz Mono & Double-Check Assertion Validation
        t4 = time.perf_counter()
        stt_payload = self.validator.validate_and_format(gated_chunk, orig_sr=self.input_sample_rate)
        dur_stage4 = (time.perf_counter() - t4) * 1000.0

        total_latency_ms = (time.perf_counter() - t_start) * 1000.0

        # Latency constraint assertion check (< 2000 ms strictly required)
        assert total_latency_ms < 2000.0, f"STRICT LATENCY VIOLATION: {total_latency_ms:.2f} ms exceeds 2.0s limit!"

        metrics = {
            "total_latency_ms": round(total_latency_ms, 2),
            "stage1_ingest_agc_ms": round(dur_stage1, 2),
            "stage2_df3_ms": round(dur_stage2, 2),
            "stage3_vad_ms": round(dur_stage3, 2),
            "stage4_validator_ms": round(dur_stage4, 2),
            "speech_probability": round(speech_prob, 4),
            "is_speech_active": is_speech_active,
        }

        return stt_payload, metrics

    def stream_process(self, chunk_generator: Generator[np.ndarray, None, None]):
        """
        Stream audio chunks from a generator through the pipeline.
        Yields STT payloads for downstream consumption.
        """
        for chunk in chunk_generator:
            stt_payload, metrics = self.process_chunk(chunk)
            yield stt_payload, metrics


if __name__ == "__main__":
    pipeline = AudioPipeline()

    # Benchmark: 500 ms audio chunk @ 48 kHz = 24,000 samples
    sample_rate_48k = 48000
    chunk_samples = 24000
    t = np.linspace(0, 0.5, chunk_samples, endpoint=False)

    # 1. Test Low-volume whisper + speech
    whisper_speech = (0.04 * np.sin(2 * np.pi * 300 * t)).astype(np.float32)
    payload, metrics = pipeline.process_chunk(whisper_speech)

    print("\n--- Pipeline Execution Report ---")
    print(f"Total Processing Latency: {metrics['total_latency_ms']} ms (Target: <800 ms, Limit: <2000 ms)")
    print(f"  Stage 1 (Ingest/AGC):  {metrics['stage1_ingest_agc_ms']} ms")
    print(f"  Stage 2 (DF3 Clean):   {metrics['stage2_df3_ms']} ms")
    print(f"  Stage 3 (Silero VAD):  {metrics['stage3_vad_ms']} ms")
    print(f"  Stage 4 (Validator):   {metrics['stage4_validator_ms']} ms")
    print(f"Speech Active: {metrics['is_speech_active']} (Prob: {metrics['speech_probability']})")
    print(f"Output Payload: SR={payload['sample_rate']} Hz, Shape={payload['audio'].shape}, Duration={payload['duration_ms']} ms")

    # Assertions on pipeline output
    assert payload["sample_rate"] == 16000
    assert len(payload["audio"]) == 8000
    assert not np.isnan(payload["audio"]).any()

    print("ALL SUBAGENTS & MASTER PIPELINE TEST PASSED SUCCESSFULLY!")
