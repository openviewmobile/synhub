#!/usr/bin/env python3
"""Send an image to a chat-completions model and print its answer."""
import base64
import json
import sys
import urllib.request

BASE = "http://ds923plus:3000/v1/chat/completions"
KEY = open("$HOME/.dsh/.credentials.yaml").read().split("NEWAPI_GATEWAY_API_KEY:")[1].split()[0]


def ask(model, image_path, prompt, detail="high"):
    b64 = base64.b64encode(open(image_path, "rb").read()).decode()
    payload = {
        "model": model,
        "max_tokens": 800,
        "temperature": 0,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}", "detail": detail}},
            ],
        }],
    }
    req = urllib.request.Request(
        BASE, data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            body = json.load(r)
        return body["choices"][0]["message"].get("content", "")
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}: {e.read().decode()[:500]}"
    except Exception as e:  # noqa: BLE001
        return f"ERROR: {type(e).__name__}: {e}"


if __name__ == "__main__":
    model, path, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
    print(ask(model, path, prompt))
