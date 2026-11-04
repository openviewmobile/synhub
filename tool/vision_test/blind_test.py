#!/usr/bin/env python3
"""Blind multi-round OCR test: generate random digit images, ask a model, auto-compare."""
import random
import re
import sys

from make_image import render
from probe import ask

MODELS = sys.argv[1:] or ["deepseek-v4.1-flash"]
ROUNDS = 4
PROMPT = "图里有一串数字。请只输出这串数字本身，不要任何其他文字。"

for model in MODELS:
    ok = 0
    print(f"--- {model} ---")
    for i in range(ROUNDS):
        digits = "".join(random.choice("0123456789") for _ in range(4))
        path = f"/tmp/blind_{i}.png"
        render(path, digits)
        answer = (ask(model, path, PROMPT) or "<EMPTY>").strip()
        got = re.sub(r"\D", "", answer)
        hit = got == digits
        ok += hit
        # truth shown only after the model answered
        print(f"  round {i + 1}: truth={digits} answer={answer!r} -> {'PASS' if hit else 'FAIL'}")
    print(f"  {model}: {ok}/{ROUNDS} correct")
