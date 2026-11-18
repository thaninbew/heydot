#!/usr/bin/env python3
"""Run with the repository .venv Python after swift build. No microphone or network."""
import os
from pathlib import Path
import subprocess
from dots_voice_wake.detectors import KeywordDetector
from dots_voice_wake.wake import wav_frames

repo = Path(__file__).resolve().parents[3]
app = repo / 'apps/HeyDot'
os.environ['HEYDOT_MODEL_DIR'] = str(app / 'Vendor/models')
executable = app / '.build/debug/heydot-engine-check'
for phrase in ('hey dot', 'hey tray'):
    for path in sorted((app / 'Tests/WakeEngineTests/Fixtures').glob('*.wav')):
        detector = KeywordDetector({'wake': phrase})
        python_hits = sum(len(detector.accept(f)) for f in wav_frames(str(path), pad_seconds=1))
        result = subprocess.check_output([str(executable), str(path), phrase], text=True)
        swift_hits = int(result.split('detections=')[1].split()[0])
        print(f'{phrase} | {path.name} | Python={python_hits} Swift={swift_hits}', flush=True)
        assert python_hits == swift_hits
