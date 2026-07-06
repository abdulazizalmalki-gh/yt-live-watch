#!/usr/bin/env python3
import sys, numpy as np, soundfile as sf
from kokoro import KPipeline
text = sys.stdin.read().strip()
out = sys.argv[1] if len(sys.argv) > 1 else ""
voice = sys.argv[2] if len(sys.argv) > 2 else "af_heart"
speed = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
if not text: sys.exit(0)
pipeline = KPipeline(lang_code="a")
parts = [a for _,_,a in pipeline(text, voice=voice, speed=speed)]
if not parts: sys.exit(0)
sf.write(out, np.concatenate(parts), 24000)
