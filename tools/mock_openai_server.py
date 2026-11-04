#!/usr/bin/env python3
"""OpenAI 兼容的 mock 服务，用来在没有厂商 key 的情况下做真机联调。

用法：
    python3 tools/mock_openai_server.py [port] [--host 0.0.0.0]

提供：
    GET  /v1/models                 → 模型列表
    POST /v1/chat/completions       → 流式（SSE）与非流式各一条路径
    POST /v1/chat/completions 带 key=bad-* → 故意返回 401（验证错误文案）
    GET  /ping                      → 探活

刻意模拟真实世界的两个坑：
    * 流式分段边界：一次 write 里塞半行（SSE 解析器必须按行缓冲）
    * **不发 `data: [DONE]`**（不少网关确实不发，客户端不能死等）
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = [
    "ds4.1-flash",          # 带点号/推理段（用户报的模型形状）
    "mock-reasoner-only",   # 只有思考、没有正文（验证新的"只说人话"报错）
    "mock-no-max-tokens",   # 不认 max_tokens，要 400 逼客户端自动重试
    "mock-1",
    "mock-large",
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 安静一点
        sys.stderr.write("[mock] " + fmt % args + "\n")

    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/ping"):
            self._json(200, {"ok": True, "models": MODELS})
            return
        if self.path.startswith("/v1/models"):
            self._json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": m, "object": "model", "owned_by": "mock"}
                        for m in MODELS
                    ],
                },
            )
            return
        self._json(404, {"error": {"message": f"no route {self.path}"}})

    def do_POST(self):
        if not self.path.startswith("/v1/chat/completions"):
            self._json(404, {"error": {"message": f"no route {self.path}"}})
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else "{}"
        try:
            req = json.loads(raw)
        except json.JSONDecodeError:
            self._json(400, {"error": {"message": "bad json"}})
            return

        auth = self.headers.get("Authorization") or ""
        if "bad-" in auth:
            # 跟真厂商一样：401 + 结构化的 error.message
            self._json(
                401,
                {
                    "error": {
                        "message": "Incorrect API key provided: bad-***",
                        "type": "invalid_request_error",
                        "code": "invalid_api_key",
                    }
                },
            )
            return

        model = req.get("model") or MODELS[0]
        user = ""
        for m in reversed(req.get("messages") or []):
            if m.get("role") == "user":
                user = m.get("content") or ""
                break

        # 兼容性分支 1：不认 `max_tokens`，只有 `max_completion_tokens` 才收
        if model == "mock-no-max-tokens" and "max_tokens" in req:
            self._json(
                400,
                {
                    "error": {
                        "message": "Unsupported parameter: 'max_tokens' is not "
                        "supported with this model. Use 'max_completion_tokens' "
                        "instead.",
                        "type": "invalid_request_error",
                    }
                },
            )
            return

        if req.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            text = (
                f"[mock:{model}] 收到 {len(user)} 字。"
                "这是一段用来验证流式链路的回答："
                "如果界面上是逐字出现的，说明 SSE 解析与增量渲染都通了。"
            )
            if model == "mock-reasoner-only":
                # 兼容性分支 2：推理模型把预算全花在 reasoning 上，正文一个字没有。
                # 客户端**不能**静默结束，必须告诉用户"只出了思考内容"。
                for piece in ("先想一下这个问题的背景……", "再比较几种可能……"):
                    payload = json.dumps(
                        {
                            "choices": [
                                {"index": 0, "delta": {"reasoning_content": piece}}
                            ]
                        },
                        ensure_ascii=False,
                    )
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.3)
                self.close_connection = True
                return
            if model == "ds4.1-flash":
                # 兼容性分支 3：先来一段 reasoning_content（不该出现在正文里），
                # 再来正文；最后带 finish_reason=length 验证"截断提示"。
                for piece in ("思考中：先看题目。", "思考中：组织语言。"):
                    payload = json.dumps(
                        {
                            "choices": [
                                {"index": 0, "delta": {"reasoning_content": piece}}
                            ]
                        },
                        ensure_ascii=False,
                    )
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.15)
            # 故意按"半个 JSON"切开，考验按行缓冲的解析器
            chunks = [text[i : i + 7] for i in range(0, len(text), 7)]
            for i, piece in enumerate(chunks):
                payload = json.dumps(
                    {"choices": [{"index": 0, "delta": {"content": piece}}]},
                    ensure_ascii=False,
                )
                frame = f"data: {payload}\n\n"
                if i == 0:
                    # 第一帧故意拆成两次写：`data: {...` 先发，再发 `}\n\n`
                    cut = len(frame) // 2
                    self.wfile.write(frame[:cut].encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.05)
                    self.wfile.write(frame[cut:].encode("utf-8"))
                else:
                    self.wfile.write(frame.encode("utf-8"))
                self.wfile.flush()
                time.sleep(0.04)
            if model == "ds4.1-flash":
                payload = json.dumps(
                    {
                        "choices": [
                            {
                                "index": 0,
                                "delta": {},
                                "finish_reason": "length",
                            }
                        ]
                    }
                )
                self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
            # 注意：这里**不发** data: [DONE]，客户端应按连接关闭收尾
            self.wfile.flush()
            self.close_connection = True
            return

        self._json(
            200,
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion",
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": f"连接成功（mock {model}）",
                        },
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20},
            },
        )


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    host = "0.0.0.0"
    if "--host" in sys.argv:
        host = sys.argv[sys.argv.index("--host") + 1]
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"[mock] listening on http://{host}:{port}/v1  (models={MODELS})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
