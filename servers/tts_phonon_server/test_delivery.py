import unittest
from unittest.mock import patch
import numpy as np
import server

class DeliveryTests(unittest.TestCase):
    def test_factual_and_questions_stay_neutral(self):
        for text in ['The meeting starts at two.', 'Great, shall I continue?', 'Stop!', 'The file is great.txt.']:
            self.assertEqual(server.delivery(text)[1], 0)

    def test_negative_cues_override_positive_opening(self):
        for text in ["Great, but the upload failed!", "I'm sorry!", "Good news? Not yet.", "Unfortunately, I can’t do that."]:
            self.assertEqual(server.delivery(text), ('calm', .15))

    def test_positive_and_hesitant(self):
        self.assertEqual(server.delivery('Congratulations!'), ('upbeat', -.3))
        self.assertEqual(server.delivery('Right away, sir.'), ('warm', -.15))
        self.assertEqual(server.delivery('Well… let me think.'), ('hesitant', .3))

    def test_tone_resets_and_text_is_unchanged(self):
        class Model:
            sample_rate = 24000
            def set_conditions(self, conditions): self.delta = conditions['duration_delta']
            def synth(self, text, **kwargs):
                calls.append((text, self.delta))
                return np.ones(240, dtype=np.float32) * .1
        calls = []
        with patch.dict(server.state, tts=Model()):
            for text in ['Wonderful!', 'The time is two.', 'I am sorry.', 'Ready.']:
                self.assertTrue(server.synthesize(text).startswith(b'RIFF'))
        self.assertEqual(calls, [('Wonderful!', -.3), ('The time is two.', 0), ('I am sorry.', .15), ('Ready.', 0)])

if __name__ == '__main__': unittest.main()
