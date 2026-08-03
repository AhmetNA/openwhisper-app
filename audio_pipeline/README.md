# Audio preprocessing pipeline

The package implements the roadmap as an independently testable Python path:

```text
sounddevice 48 kHz mono
  -> PeakRMSNormalizer
  -> DeepFilterNet3Cleaner (500 ms chunks)
  -> SileroVADGate (16 kHz scoring, 0.5 threshold)
  -> OutputValidator (SoXR HQ, 16 kHz mono float32)
```

Install the optional runtime dependencies with `python3 -m pip install -r requirements-audio.txt`.
The model backends are lazy: importing and unit-testing the package does not load or download
DeepFilterNet/Silero models. For production, pass a local Silero ONNX model path:

```python
from audio_pipeline import AudioPreprocessingPipeline, SileroVADGate

pipeline = AudioPreprocessingPipeline(
    gate=SileroVADGate(model_path="/path/to/silero_vad.onnx")
)
```

The current OpenWhisper app remains Swift/WhisperKit and already converts its capture path to
16 kHz mono. This package is therefore not automatically inserted into the Swift callback.
Benchmark DFN3 latency and model accuracy on the target Mac before replacing that path.
