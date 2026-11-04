#!/usr/bin/env python3
"""按 ~/.dsh/settings.yaml 的配置，把一张图发给视觉模型，验证配置是否生效。

用法: python3 scripts/vision_probe.py <图片路径> [模型ID] [提问]
默认模型 glm-5.3-flash（实测 6 个模型里最快且全部答对）。
"""
import base64, json, os, re, sys, urllib.request

def load_cfg():
    cfg = open(os.path.expanduser("~/.dsh/settings.yaml")).read()
    cred = open(os.path.expanduser("~/.dsh/.credentials.yaml")).read()
    base = re.search(r'baseURL:\s*(\S+)', cfg).group(1)
    env = re.search(r'apiKeyEnv:\s*(\S+)', cfg)
    key = None
    if env:
        m = re.search(rf'{env.group(1)}:\s*(\S+)', cred)
        if m:
            key = m.group(1)
    key = key or os.environ.get("NEWAPI_GATEWAY_API_KEY")
    return base, key

def main():
    path = sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else "glm-5.3-flash"
    prompt = sys.argv[3] if len(sys.argv) > 3 else \
        "请逐条列出图中所有可见文字（中英文），并说明有哪些控件。只描述看到的，不要猜测。"

    base, key = load_cfg()
    img = base64.b64encode(open(path, "rb").read()).decode()
    body = {"model": model, "max_tokens": 1500, "messages": [{"role": "user", "content": [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{img}"}}]}]}
    req = urllib.request.Request(f"{base}/chat/completions", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        j = json.loads(r.read().decode())
    print(j["choices"][0]["message"]["content"])
    u = j.get("usage", {})
    it = (u.get("prompt_tokens_details") or {}).get("image_tokens")
    print(f"\n[usage] prompt={u.get('prompt_tokens')} completion={u.get('completion_tokens')} "
          f"image_tokens={it}", file=sys.stderr)

main()
