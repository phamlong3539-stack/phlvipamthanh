#!/usr/bin/env python3
"""
Generate build/generated_key.h for PHLVoiceEngine.dylib.
If SIGNING_SECRET is provided via environment or --secret, transforms it into a
split, bit-rotated, XOR-masked byte table reconstructed only in stack memory
so no plain-text secret exists in source code or binary strings.
If omitted, emits PHL_HAS_EMBEDDED_HMAC_KEY = 0 (Keychain Seal + SHA-256 mode).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def rol8(val: int, bits: int) -> int:
    bits &= 7
    return ((val << bits) | (val >> (8 - bits))) & 0xFF


def emit_header(secret_bytes: bytes, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if not secret_bytes:
        out_path.write_text(
            "// Auto-generated (Zero-Secret Mode)\n"
            "#pragma once\n"
            "#define PHL_HAS_EMBEDDED_HMAC_KEY 0\n",
            encoding="utf-8",
        )
        return

    if len(secret_bytes) > 256:
        raise ValueError("SIGNING_SECRET vượt quá độ dài tối đa 256 byte.")

    masks = os.urandom(len(secret_bytes))
    encoded = []
    for idx, b in enumerate(secret_bytes):
        rot = (idx % 7) + 1
        encoded.append(rol8(b ^ masks[idx], rot))

    mask_hex = ", ".join(f"0x{m:02x}" for m in masks)
    enc_hex = ", ".join(f"0x{e:02x}" for e in encoded)

    content = f"""// Auto-generated at build time — DO NOT COMMIT
#pragma once
#include <stddef.h>
#include <stdint.h>

#define PHL_HAS_EMBEDDED_HMAC_KEY 1

static inline void PHLReconstructHMACKey(uint8_t *outBuf, size_t maxLen, size_t *outLen) {{
    static const uint8_t kMask[{len(secret_bytes)}] = {{ {mask_hex} }};
    static const uint8_t kEnc[{len(secret_bytes)}]  = {{ {enc_hex} }};
    const size_t n = sizeof(kEnc);
    if (!outBuf || maxLen < n) {{
        if (outLen) *outLen = 0;
        return;
    }}
    volatile uint8_t *dst = outBuf;
    for (size_t i = 0; i < n; ++i) {{
        uint8_t r = (uint8_t)((i % 7U) + 1U);
        uint8_t e = kEnc[i];
        uint8_t unrot = (uint8_t)((e >> r) | (e << (8U - r)));
        dst[i] = (uint8_t)(unrot ^ kMask[i]);
    }}
    if (outLen) *outLen = n;
}}
"""
    out_path.write_text(content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="Output header path")
    parser.add_argument("--secret", default=os.environ.get("VOICE_SIGNING_SECRET", ""), help="Signing secret")
    args = parser.parse_args()

    emit_header(args.secret.strip().encode("utf-8"), Path(args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
