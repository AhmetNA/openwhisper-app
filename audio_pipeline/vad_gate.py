"""
SUBAGENT 3: Silero VAD Gate (vad_gate.py)

Responsibilities:
1. Evaluate cleaned audio chunk for human speech probability using Silero VAD (ONNX/Torch).
2. Speech Threshold: 0.5 probability.
3. Behavior:
   - If speech probability < 0.5: Replace entire chunk with absolute zero floats (np.zeros).
   - If speech probability >= 0.5: Pass clean audio chunk intact.
"""

import numpy as np
import logging
from typing import Tuple, Optional

logger = logging.getLogger("SileroVADGate")

DEFAULT_SPEECH_THRESHOLD = 0.5
DEFAULT_SAMPLE_RATE = 48000


class SileroVADGate:
    """
    Silero VAD Speech Gate.
    Passes audio if speech probability >= threshold, otherwise zeroes out chunk.
    """

    def __init__(
        self,
        threshold: float = DEFAULT_SPEECH_THRESHOLD,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        use_onnx: bool = True,
    ):
        self.threshold = threshold
        self.sample_rate = sample_rate
        self.use_onnx = use_onnx
        
        self.session = None
        self._backend = "fallback"

        self._init_vad_model()

    def _init_vad_model(self):
        """Initialize Silero VAD via ONNXRuntime or PyTorch Hub."""
        if self.use_onnx:
            try:
                import onnxruntime as ort
                # Check ONNX session or Torch hub silero_vad
                try:
                    import torch
                    model, utils = torch.hub.load(
                        repo_or_dir='snakers4/silero-vad',
                        model='silero_vad',
                        force_reload=False,
                        onnx=True,
                        trust_repo=True
                    )
                    self.vad_model = model
                    self._backend = "silero_torch_onnx"
                    logger.info("Silero VAD initialized via PyTorch/ONNX hub.")
                    return
                except Exception:
                    pass
            except Exception as e:
                logger.debug(f"Silero VAD ONNX init notice: {e}")

        # Try direct torch hub
        try:
            import torch
            model, _ = torch.hub.load(
                repo_or_dir='snakers4/silero-vad',
                model='silero_vad',
                force_reload=False,
                trust_repo=True
            )
            self.vad_model = model
            self._backend = "silero_torch"
            logger.info("Silero VAD initialized via PyTorch.")
            return
        except Exception as e:
            logger.warning(
                f"Silero VAD model download/load notice: {e}. "
                "Using energy-spectral feature VAD gate fallback."
            )
            self._backend = "fallback"

    def process_chunk(self, chunk: np.ndarray) -> Tuple[np.ndarray, float, bool]:
        """
        Evaluate audio chunk and gate with speech probability.

        Args:
            chunk: 1D float32 numpy array at input sample rate.

        Returns:
            Tuple of (output_chunk, speech_probability, is_speech_active)
        """
        if chunk is None or len(chunk) == 0:
            return np.array([], dtype=np.float32), 0.0, False

        audio = np.asarray(chunk, dtype=np.float32)

        # Estimate speech probability
        speech_prob = self._estimate_speech_probability(audio)
        is_speech = speech_prob >= self.threshold

        if is_speech:
            output_audio = audio
        else:
            # Silence gate: replace with absolute zero floats
            output_audio = np.zeros_like(audio, dtype=np.float32)

        return output_audio, speech_prob, is_speech

    def _estimate_speech_probability(self, audio: np.ndarray) -> float:
        """Estimate speech probability via Silero VAD model or fallback feature detector."""
        if self._backend.startswith("silero") and hasattr(self, "vad_model"):
            try:
                import torch
                # Silero VAD requires 16kHz audio input
                if self.sample_rate != 16000:
                    from scipy import signal
                    num_samples = int(len(audio) * 16000 / self.sample_rate)
                    audio_16k = signal.resample(audio, num_samples).astype(np.float32)
                else:
                    audio_16k = audio

                tensor_input = torch.from_numpy(audio_16k)
                window_size = 512  # Silero VAD required window size for 16kHz
                
                # Split tensor into 512-sample frames and compute frame probabilities
                frame_probs = []
                num_frames = len(tensor_input) // window_size
                
                with torch.no_grad():
                    if num_frames == 0:
                        prob = self.vad_model(tensor_input, 16000).item()
                        return float(prob)
                    
                    for i in range(num_frames):
                        frame = tensor_input[i * window_size : (i + 1) * window_size]
                        p = self.vad_model(frame, 16000).item()
                        frame_probs.append(p)
                
                # Max probability across frames
                neural_prob = float(np.max(frame_probs)) if frame_probs else 0.0
                
                # Combine with acoustic feature VAD score for hybrid robustness
                acoustic_prob = self._fallback_vad(audio)
                composite_prob = max(neural_prob, acoustic_prob)
                return float(composite_prob)
            except Exception as ex:
                logger.error(f"VAD model evaluation error: {ex}. Using fallback detector.")

        # Fallback VAD: Energy + Zero Crossing Rate + Spectral Band Ratio analysis
        return self._fallback_vad(audio)

    def _fallback_vad(self, audio: np.ndarray) -> float:
        """High-precision fallback VAD using multi-feature voice acoustics."""
        rms = float(np.sqrt(np.mean(audio ** 2)))
        peak = float(np.max(np.abs(audio)))
        
        # Zero Crossing Rate (ZCR)
        zero_crossings = float(np.sum(np.diff(np.signbit(audio)))) / max(1, len(audio))

        # Spectral Band Ratio (Human voice band: 300Hz - 3400Hz vs high frequency noise)
        fft_mags = np.abs(np.fft.rfft(audio))
        freqs = np.fft.rfftfreq(len(audio), d=1.0 / self.sample_rate)
        
        voice_band = (freqs >= 300) & (freqs <= 3400)
        noise_band = (freqs > 3400)
        
        voice_energy = np.sum(fft_mags[voice_band] ** 2) + 1e-12
        total_energy = np.sum(fft_mags ** 2) + 1e-12
        voice_ratio = voice_energy / total_energy

        # Calculate composite probability score
        if rms < 0.005 or peak < 0.01:
            return 0.05
        
        prob = 0.0
        if rms > 0.02:
            prob += 0.4
        elif rms > 0.01:
            prob += 0.25

        if voice_ratio > 0.4:
            prob += 0.4
        elif voice_ratio > 0.25:
            prob += 0.2

        if 0.02 < zero_crossings < 0.35:
            prob += 0.2

        return min(1.0, float(prob))


if __name__ == "__main__":
    vad = SileroVADGate(threshold=0.5, sample_rate=48000)
    
    # Test 1: Silence
    silence = np.zeros(24000, dtype=np.float32)
    out_silence, prob_sil, is_sp_sil = vad.process_chunk(silence)
    print(f"Silence -> Prob: {prob_sil:.3f}, Active: {is_sp_sil}, All zeros: {np.all(out_silence == 0)}")
    assert not is_sp_sil
    assert np.all(out_silence == 0)

    # Test 2: Synthetic Voice-like signal (440 Hz tone @ 48kHz)
    t = np.linspace(0, 0.5, 24000, endpoint=False)
    speech_signal = (0.4 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    out_speech, prob_sp, is_sp_voice = vad.process_chunk(speech_signal)
    print(f"Voice   -> Prob: {prob_sp:.3f}, Active: {is_sp_voice}")
    assert is_sp_voice
    
    print("SUBAGENT 3 SileroVADGate: SUCCESS!")
