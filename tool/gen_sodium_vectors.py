#!/usr/bin/env python3
"""用本机真正的 libsodium 生成测试向量（Phase 7 E2EE 用）。

Dart 侧是纯 Dart 实现（pinenacl + blake2b），必须拿 **真 libsodium 的输出**
当基准，否则加解密对不对根本没法验。本脚本通过 ctypes 调
`/opt/homebrew/lib/libsodium.dylib`，产出：

  * `test/support/sodium_vectors.dart` —— 离线测试用的固定向量
  * `tool/sodium_vectors.json` —— 同一批数据（给交叉校验脚本用）

用法：
    python3 tool/gen_sodium_vectors.py            # 生成向量
    python3 tool/gen_sodium_vectors.py --verify   # 校验 Dart 产出的 seal（双向互通）
"""
from __future__ import annotations

import base64
import ctypes
import ctypes.util
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DART_VECTORS = os.path.join(ROOT, "test/support/sodium_vectors.dart")
JSON_VECTORS = os.path.join(ROOT, "tool/sodium_vectors.json")
DART_OUT = os.path.join(ROOT, "tool/_dart_sodium_out.json")


def load_sodium() -> ctypes.CDLL:
    for cand in (
        "/opt/homebrew/lib/libsodium.dylib",
        "/usr/local/lib/libsodium.dylib",
        ctypes.util.find_library("sodium"),
    ):
        if cand and os.path.exists(cand):
            lib = ctypes.CDLL(cand)
            break
    else:
        raise SystemExit("找不到 libsodium（brew install libsodium）")
    lib.sodium_init()
    return lib


def buf(n: int) -> ctypes.Array:
    return ctypes.create_string_buffer(n)


def b2s(b: bytes) -> str:
    return base64.b64encode(b).decode()


def hexs(b: bytes) -> str:
    return b.hex()


def main() -> None:
    lib = load_sodium()

    lib.crypto_generichash.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                       ctypes.c_void_p, ctypes.c_ulonglong,
                                       ctypes.c_void_p, ctypes.c_size_t]
    lib.crypto_secretbox_easy.argtypes = [ctypes.c_void_p] * 2 + [
        ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_void_p]
    lib.crypto_secretbox_open_easy.argtypes = lib.crypto_secretbox_easy.argtypes
    lib.crypto_box_seed_keypair.argtypes = [ctypes.c_void_p] * 3
    lib.crypto_box_seal.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                    ctypes.c_ulonglong, ctypes.c_void_p]
    lib.crypto_box_seal_open.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                         ctypes.c_ulonglong, ctypes.c_void_p,
                                         ctypes.c_void_p]
    lib.crypto_kx_seed_keypair.argtypes = [ctypes.c_void_p] * 3
    lib.crypto_kx_client_session_keys.argtypes = [ctypes.c_void_p] * 5
    lib.crypto_kx_server_session_keys.argtypes = [ctypes.c_void_p] * 5

    # ---------- 1. BLAKE2b-256（= crypto_generichash，passcode 派生私钥的口令）----------
    passcode = "flt-passcode-2026"
    out = buf(32)
    lib.crypto_generichash(out, 32, passcode.encode(), len(passcode), None, 0)
    passcode_key = out.raw[:32]

    # ---------- 2. secretbox（消息 / 文件名 / 文件体 / 私钥 都用它）----------
    key = bytes(range(32))
    nonce = bytes(range(24))
    msg = "中文消息 with emoji 🙂".encode()
    ct = buf(len(msg) + 16)
    lib.crypto_secretbox_easy(ct, msg, len(msg), nonce, key)
    secretbox_ct = ct.raw[: len(msg) + 16]

    # ---------- 3. crypto_box_seal（频道密钥分发）----------
    seed_r = bytes(range(32, 64))
    pk = buf(32)
    sk = buf(32)
    lib.crypto_box_seed_keypair(pk, sk, seed_r)
    recip_pk, recip_sk = pk.raw[:32], sk.raw[:32]
    chan_key = bytes(range(64, 96))
    sealed = buf(len(chan_key) + 48)
    lib.crypto_box_seal(sealed, chan_key, len(chan_key), recip_pk)
    sealed_bytes = sealed.raw[: len(chan_key) + 48]
    # 回解一次确认向量本身是对的
    opened = buf(len(chan_key))
    assert lib.crypto_box_seal_open(opened, sealed_bytes, len(sealed_bytes),
                                    recip_pk, recip_sk) == 0
    assert opened.raw[: len(chan_key)] == chan_key

    # ---------- 4. crypto_kx（设备 SAS 校验）----------
    seed_c = bytes(range(96, 128))
    c_pk, c_sk = buf(32), buf(32)
    lib.crypto_kx_seed_keypair(c_pk, c_sk, seed_c)
    seed_s = bytes(range(128, 160))
    s_pk, s_sk = buf(32), buf(32)
    lib.crypto_kx_seed_keypair(s_pk, s_sk, seed_s)
    client_rx, client_tx = buf(32), buf(32)
    lib.crypto_kx_client_session_keys(client_rx, client_tx, c_pk, c_sk, s_pk)
    server_rx, server_tx = buf(32), buf(32)
    lib.crypto_kx_server_session_keys(server_rx, server_tx, s_pk, s_sk, c_pk)
    # 双向必须对得上：client_tx == server_rx，client_rx == server_tx
    assert client_tx.raw[:32] == server_rx.raw[:32]
    assert client_rx.raw[:32] == server_tx.raw[:32]

    vectors = {
        "passcode": passcode,
        "passcodeKey": b2s(passcode_key),
        "secretbox": {
            "key": b2s(key),
            "nonce": b2s(nonce),
            "plaintext": msg.decode(),
            "ciphertext": b2s(secretbox_ct),
        },
        "seal": {
            "recipientPublicKey": b2s(recip_pk),
            "recipientPrivateKey": b2s(recip_sk),
            "plaintextBase64": b2s(chan_key),
            "sealed": b2s(sealed_bytes),
        },
        "kx": {
            "clientPublicKey": b2s(c_pk.raw[:32]),
            "clientPrivateKey": b2s(c_sk.raw[:32]),
            "serverPublicKey": b2s(s_pk.raw[:32]),
            "serverPrivateKey": b2s(s_sk.raw[:32]),
            "clientRx": b2s(client_rx.raw[:32]),
            "clientTx": b2s(client_tx.raw[:32]),
            "serverRx": b2s(server_rx.raw[:32]),
            "serverTx": b2s(server_tx.raw[:32]),
        },
    }

    with open(JSON_VECTORS, "w") as f:
        json.dump(vectors, f, indent=2, ensure_ascii=False)

    dart = f'''// 由 tool/gen_sodium_vectors.py 生成 —— 别手改。
//
// 基准是**本机真 libsodium**（brew 的 libsodium.dylib）：
// 离线测试拿这些固定向量校验纯 Dart 实现（pinenacl + blake2b）是否与
// libsodium 完全一致——E2EE 只要差一个字节，跟服务端/其它客户端就对不上了。
// ignore_for_file: lines_longer_than_80_chars

class SodiumVectors {{
  static const passcode = '{passcode}';

  /// blake2b-256(passcode) —— `crypto_generichash`，私钥加密用的口令密钥
  static const passcodeKey = '{b2s(passcode_key)}';

  static const secretboxKey = '{b2s(key)}';
  static const secretboxNonce = '{b2s(nonce)}';
  static const secretboxPlaintext = '{msg.decode()}';
  static const secretboxCiphertext = '{b2s(secretbox_ct)}';

  static const sealRecipientPublicKey = '{b2s(recip_pk)}';
  static const sealRecipientPrivateKey = '{b2s(recip_sk)}';
  static const sealPlaintext = '{b2s(chan_key)}';
  static const sealSealed = '{b2s(sealed_bytes)}';

  static const kxClientPublicKey = '{b2s(c_pk.raw[:32])}';
  static const kxClientPrivateKey = '{b2s(c_sk.raw[:32])}';
  static const kxServerPublicKey = '{b2s(s_pk.raw[:32])}';
  static const kxServerPrivateKey = '{b2s(s_sk.raw[:32])}';
  static const kxClientRx = '{b2s(client_rx.raw[:32])}';
  static const kxClientTx = '{b2s(client_tx.raw[:32])}';
  static const kxServerRx = '{b2s(server_rx.raw[:32])}';
  static const kxServerTx = '{b2s(server_tx.raw[:32])}';
}}
'''
    with open(DART_VECTORS, "w") as f:
        f.write(dart)

    print(f"已生成 {DART_VECTORS}")
    print(f"已生成 {JSON_VECTORS}")

    if "--verify" in sys.argv:
        verify_dart(lib, vectors)


def verify_dart(lib: ctypes.CDLL, vectors: dict) -> None:
    """跑 Dart 侧的双向互通脚本，再用 libsodium 校验它的输出。"""
    if os.path.exists(DART_OUT):
        os.remove(DART_OUT)
    env = dict(os.environ)
    env["PATH"] = "<flutter-sdk>/bin:" + env.get("PATH", "")
    subprocess.run(
        ["dart", "run", "tool/sodium_interop.dart"],
        cwd=ROOT, env=env, check=True,
    )
    with open(DART_OUT) as f:
        dart = json.load(f)

    # ① Dart 加的 secretbox，libsodium 能解开
    key = base64.b64decode(vectors["secretbox"]["key"])
    nonce = base64.b64decode(dart["secretboxNonce"])
    ct = base64.b64decode(dart["secretboxCiphertext"])
    out = buf(len(ct))
    rc = lib.crypto_secretbox_open_easy(out, ct, len(ct), nonce, key)
    assert rc == 0, "secretbox 解不开"
    assert out.raw[: len(ct) - 16].decode() == dart["secretboxPlaintext"], "secretbox 内容不一致"

    # ② Dart seal 的频道密钥，libsodium 用收件人私钥能开
    pk = base64.b64decode(vectors["seal"]["recipientPublicKey"])
    sk = base64.b64decode(vectors["seal"]["recipientPrivateKey"])
    sealed = base64.b64decode(dart["sealed"])
    plain = buf(len(sealed))
    rc = lib.crypto_box_seal_open(plain, sealed, len(sealed), pk, sk)
    assert rc == 0, "seal 解不开"
    assert base64.b64encode(plain.raw[: len(sealed) - 48]).decode() == \
        dart["sealPlaintext"], "seal 内容不一致"

    # ③ Dart 的 kx 会话密钥要和 libsodium 一致
    c_pk = base64.b64decode(dart["kxClientPublicKey"])
    c_sk = base64.b64decode(vectors["kx"]["clientPrivateKey"])
    s_pk = base64.b64decode(dart["kxServerPublicKey"])
    rx, tx = buf(32), buf(32)
    assert lib.crypto_kx_client_session_keys(rx, tx, c_pk, c_sk, s_pk) == 0
    assert b2s(rx.raw[:32]) == dart["kxRx"], "kx rx 不一致"
    assert b2s(tx.raw[:32]) == dart["kxTx"], "kx tx 不一致"

    print("交叉校验通过：Dart ↔ libsodium 的 secretbox / seal / kx 全对 ✓")


if __name__ == "__main__":
    main()
