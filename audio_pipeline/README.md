# Audio Pre-Processing Pipeline (Whisper / Large-Turbo Target)

High-performance modular Python audio pre-processing pipeline for macOS (Apple Silicon).

## Architecture

```
[Mic Input @ 48kHz]
        │
        ▼
[Subagent 1: Audio Ingestion & AGC Normalizer]  (audio_ingest.py)
        │ - Peak/RMS Normalization to -6 dB FS
        │
        ▼
[Subagent 2: DeepFilterNet 3 Engine]           (df_cleaner.py)
        │ - Deep noise suppression (attenuation_limit = -100 dB)
        │
        ▼
[Subagent 3: Silero VAD Gate]                  (vad_gate.py)
        │ - Evaluates speech probability
        │ - Zeroes out non-speech (<0.5 prob)
        │
        ▼
[Subagent 4: Resampler & Output Validator]     (output_validator.py)
        │ - High quality resampling (48 kHz -> 16 kHz Mono)
        │ - STT Handshake assertions (16kHz, Mono, float32, NaN-free)
        ▼
[ Downstream Whisper-Large-V3-Turbo STT Model ]
```

## Quick Start

### 1. Run Unit Tests
```bash
python3 audio_pipeline/test_pipeline.py
```

### 2. Basic Usage in Python
```python
from audio_pipeline.pipeline import AudioPipeline
import numpy as np

# Initialize pipeline
pipeline = AudioPipeline(
    input_sample_rate=48000,
    target_sample_rate=16000,
    attenuation_limit=-100.0,
    vad_threshold=0.5
)

# Process 500 ms audio chunk (24,000 samples @ 48 kHz)
raw_chunk = np.random.randn(24000).astype(np.float32)
stt_payload, metrics = pipeline.process_chunk(raw_chunk)

print("STT Payload:", stt_payload)
# Output: {"audio": np.ndarray(8000,), "sample_rate": 16000, "duration_ms": 500.0}

print("Latency & Metrics:", metrics)
# Output: {"total_latency_ms": ..., "is_speech_active": True, ...}
```

## Output Payload Specification

The output dictionary returned by `pipeline.process_chunk()` strictly satisfies downstream STT requirements:

| Parameter | Type | Value / Constraint |
|---|---|---|
| `audio` | `np.ndarray` | `dtype=np.float32`, Single channel (1D array) |
| `sample_rate` | `int` | Strictly `16000` Hz |
| `duration_ms` | `float` | Duration of audio chunk in milliseconds |
