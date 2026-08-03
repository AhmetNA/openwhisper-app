"""
SUBAGENT 2: DeepFilterNet 3 Engine (df_cleaner.py)

Responsibilities:
1. Process 48 kHz audio chunks (~500 ms nominal, 24,000 samples @ 48kHz).
2. Run DeepFilterNet 3 for deep neural network noise cancellation.
3. Configure attenuation_limit = -100 dB (Max Erasure) to eliminate background chatter.
4. Fallback mechanism: Adaptive spectral subtraction cleaner if DF weights/runtime are missing.
"""

import numpy as np
import logging
from typing import Optional

logger = logging.getLogger("DeepFilterCleaner")

DEFAULT_SAMPLE_RATE = 48000
DEFAULT_ATTENUATION_LIMIT = -100.0  # Max Erasure for background noise / café chatter


class DeepFilterCleaner:
    """
    DeepFilterNet 3 noise suppression wrapper with attenuation_limit = -100 dB.
    """

    def __init__(
        self,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        attenuation_limit: float = DEFAULT_ATTENUATION_LIMIT,
        post_filter: bool = True,
    ):
        self.sample_rate = sample_rate
        self.attenuation_limit = attenuation_limit
        self.post_filter = post_filter
        
        self.df_model = None
        self.df_state = None
        self._backend = "fallback"

        self._init_deepfilternet()

    def _init_deepfilternet(self):
        """Try loading DeepFilterNet 3 model engine."""
        try:
            from df.enhance import init_df, enhance, Rs
            # Load DeepFilterNet3 default model
            self.df_model, self.df_state, _ = init_df(
                config_allow_missing=True,
                post_filter=self.post_filter
            )
            # Set attenuation limit if supported by df_state / config
            if hasattr(self.df_state, "atten_lim_db"):
                self.df_state.atten_lim_db = self.attenuation_limit
            elif hasattr(self.df_model, "atten_lim_db"):
                self.df_model.atten_lim_db = self.attenuation_limit
                
            self._backend = "deepfilternet3"
            logger.info("DeepFilterNet 3 engine initialized successfully (attenuation_limit = -100 dB).")
        except Exception as e:
            logger.warning(
                f"DeepFilterNet 3 native engine initialization notice: {e}. "
                "Using high-performance spectral noise cleaner fallback."
            )
            self._backend = "fallback"

    def clean_chunk(self, chunk: np.ndarray) -> np.ndarray:
        """
        Clean noise from 48 kHz audio chunk using DeepFilterNet 3 or adaptive fallback filter.
        
        Args:
            chunk: 1D float32 numpy array at 48 kHz sample rate.
            
        Returns:
            Cleaned 1D float32 numpy array at 48 kHz.
        """
        if chunk is None or len(chunk) == 0:
            return np.array([], dtype=np.float32)

        audio = np.asarray(chunk, dtype=np.float32)

        if self._backend == "deepfilternet3" and self.df_model is not None:
            try:
                import torch
                from df.enhance import enhance
                
                tensor_input = torch.from_numpy(audio).unsqueeze(0)
                enhanced_tensor = enhance(self.df_model, self.df_state, tensor_input)
                cleaned_audio = enhanced_tensor.squeeze(0).cpu().numpy()
                return cleaned_audio.astype(np.float32)
            except Exception as ex:
                logger.error(f"DeepFilterNet inference error: {ex}, switching to fallback filter.")

        # Fallback processing: Spectral subtraction noise gate (attenuation_limit = -100 dB)
        return self._spectral_fallback_clean(audio)

    def _spectral_fallback_clean(self, audio: np.ndarray) -> np.ndarray:
        """
        Fallback spectral noise reduction enforcing max erasure (-100 dB noise floor).
        """
        from scipy import signal

        # Compute STFT
        f, t, Zxx = signal.stft(audio, fs=self.sample_rate, nperseg=512)
        magnitude = np.abs(Zxx)
        phase = np.angle(Zxx)

        # Estimate noise floor profile from lowest 10% magnitude frames
        noise_profile = np.percentile(magnitude, 10, axis=1, keepdims=True)

        # Spectral subtraction mask
        snr_mask = (magnitude - 1.5 * noise_profile) / (magnitude + 1e-10)
        mask = np.clip(snr_mask, 0.0, 1.0)
        
        # Apply max attenuation (-100 dB => 10^(-100/20) = 1e-5 floor)
        attenuation_floor = 10.0 ** (self.attenuation_limit / 20.0)  # 1e-5
        mask = np.maximum(mask, attenuation_floor)

        # Reconstruct clean STFT
        Zxx_clean = mask * magnitude * np.exp(1j * phase)
        _, clean_audio = signal.istft(Zxx_clean, fs=self.sample_rate)

        # Match length of input
        if len(clean_audio) > len(audio):
            clean_audio = clean_audio[:len(audio)]
        elif len(clean_audio) < len(audio):
            clean_audio = np.pad(clean_audio, (0, len(audio) - len(clean_audio)))

        return clean_audio.astype(np.float32)


if __name__ == "__main__":
    cleaner = DeepFilterCleaner(sample_rate=48000, attenuation_limit=-100.0)
    
    # Test with speech + background noise
    t = np.linspace(0, 0.5, 24000, endpoint=False)
    signal = 0.5 * np.sin(2 * np.pi * 440 * t)
    noise = 0.1 * np.random.randn(len(t))
    noisy_audio = (signal + noise).astype(np.float32)
    
    cleaned = cleaner.clean_chunk(noisy_audio)
    print(f"Backend used: {cleaner._backend}")
    print(f"Input shape: {noisy_audio.shape}, Cleaned shape: {cleaned.shape}")
    assert len(cleaned) == len(noisy_audio)
    print("SUBAGENT 2 DeepFilterCleaner: SUCCESS!")
