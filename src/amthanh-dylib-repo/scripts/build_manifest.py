#!/usr/bin/env python3
"""
PHL Voice & Music Engine - Automated Manifest & DSP Profile Builder
Validates admin/config.json, analyzes 1 reference source audio file per voice,
synthesizes authentic DSP parameters, signs dist/manifest.json with HMAC-SHA256
(via VOICE_SIGNING_SECRET), and writes all artifacts atomically.
"""

from __future__ import annotations

import argparse
import cmath
import hashlib
import hmac
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VOICE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,63}$")

DSP_BOUNDS: dict[str, tuple[float, float]] = {
    "pitch_semitones": (-12.0, 12.0),
    "formant_shift": (0.72, 1.38),
    "eq_low_db": (-9.0, 9.0),
    "eq_mid_db": (-9.0, 9.0),
    "eq_high_db": (-9.0, 9.0),
    "noise_gate_db": (-60.0, -18.0),
    "compressor_threshold_db": (-36.0, -4.0),
    "compressor_ratio": (1.2, 8.0),
    "limiter_ceiling_db": (-3.0, -0.2),
    "naturalness": (0.1, 1.0),
}


class ValidationError(Exception):
    """Raised when configuration, audio input, or signing secret is invalid."""


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def canonical_json_bytes(obj: Any) -> bytes:
    """Produce deterministic UTF-8 compact JSON matching the iOS verifier."""
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def atomic_write_bytes(target_path: Path, data: bytes) -> None:
    """Write bytes to a temp file in target_path.parent and atomically replace."""
    target_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target_path.name}.",
        suffix=".tmp",
        dir=str(target_path.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(tmp_path), str(target_path))
    except Exception:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
        raise


def atomic_write_json(target_path: Path, obj: Any) -> bytes:
    encoded = (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    atomic_write_bytes(target_path, encoded)
    return encoded


def resolve_safe_path(repo_root: Path, rel_path: str, field_name: str) -> Path:
    if not isinstance(rel_path, str) or not rel_path.strip():
        raise ValidationError(f"Trường '{field_name}' phải là chuỗi đường dẫn hợp lệ.")
    if "\x00" in rel_path or rel_path.startswith(("/", "\\")):
        raise ValidationError(f"Đường dẫn không an toàn ở '{field_name}': {rel_path}")
    norm = rel_path.replace("\\", "/")
    if ".." in norm.split("/"):
        raise ValidationError(f"Đường dẫn không an toàn ở '{field_name}': {rel_path}")
    resolved = (repo_root / norm).resolve()
    root_resolved = repo_root.resolve()
    if root_resolved not in resolved.parents and resolved != root_resolved:
        raise ValidationError(f"Đường dẫn thoát khỏi thư mục repo ở '{field_name}': {rel_path}")
    return resolved


def decode_wav_pcm(wav_path: Path) -> tuple[list[float], int]:
    """Decode uncompressed integer PCM WAV to mono float samples in [-1, 1]."""
    with wave.open(str(wav_path), "rb") as wf:
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        sample_rate = wf.getframerate()
        frame_count = wf.getnframes()
        if channels < 1 or sample_rate < 8000 or frame_count < 1:
            raise ValidationError(f"File WAV không hợp lệ hoặc rỗng: {wav_path}")

        max_frames = min(frame_count, sample_rate * 20)
        raw = wf.readframes(max_frames)

    total_samples = len(raw) // sampwidth
    if total_samples == 0:
        raise ValidationError(f"Không đọc được frame PCM từ {wav_path}")

    samples: list[float] = []
    if sampwidth == 1:
        unpacked = struct.unpack(f"<{total_samples}B", raw[:total_samples])
        floats = [(v - 128) / 128.0 for v in unpacked]
    elif sampwidth == 2:
        unpacked = struct.unpack(f"<{total_samples}h", raw[: total_samples * 2])
        floats = [v / 32768.0 for v in unpacked]
    elif sampwidth == 3:
        floats = []
        for idx in range(0, total_samples * 3, 3):
            b0, b1, b2 = raw[idx], raw[idx + 1], raw[idx + 2]
            val = b0 | (b1 << 8) | (b2 << 16)
            if val & 0x800000:
                val -= 0x1000000
            floats.append(val / 8388608.0)
    elif sampwidth == 4:
        unpacked = struct.unpack(f"<{total_samples}i", raw[: total_samples * 4])
        floats = [v / 2147483648.0 for v in unpacked]
    else:
        raise ValidationError(f"Độ sâu bit PCM không hỗ trợ ({sampwidth * 8}-bit): {wav_path}")

    if channels == 1:
        samples = floats
    else:
        usable = (len(floats) // channels) * channels
        inv_ch = 1.0 / channels
        samples = [
            sum(floats[i : i + channels]) * inv_ch
            for i in range(0, usable, channels)
        ]

    return samples, sample_rate


def load_audio_16k(audio_path: Path) -> tuple[list[float], int]:
    """Load WAV natively or convert any format via ffmpeg into 16kHz mono float."""
    if not audio_path.is_file():
        raise ValidationError(f"Không tìm thấy file âm thanh gốc: {audio_path}")
    if audio_path.stat().st_size == 0:
        raise ValidationError(f"File âm thanh gốc bị rỗng (0 byte): {audio_path}")

    samples: list[float] | None = None
    orig_sr = 16000

    if audio_path.suffix.lower() == ".wav":
        try:
            samples, orig_sr = decode_wav_pcm(audio_path)
        except wave.Error:
            samples = None

    if samples is None:
        ffmpeg_bin = shutil.which("ffmpeg")
        if not ffmpeg_bin:
            raise ValidationError(
                f"File '{audio_path.name}' cần ffmpeg để giải mã (không tìm thấy ffmpeg trên PATH)."
            )
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_wav:
            tmp_wav_path = Path(tmp_wav.name)
        try:
            cmd = [
                ffmpeg_bin,
                "-v",
                "error",
                "-y",
                "-i",
                str(audio_path),
                "-t",
                "20",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-acodec",
                "pcm_s16le",
                str(tmp_wav_path),
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
            if proc.returncode != 0:
                raise ValidationError(
                    f"ffmpeg không giải mã được '{audio_path.name}': {proc.stderr.strip()}"
                )
            samples, orig_sr = decode_wav_pcm(tmp_wav_path)
        finally:
            tmp_wav_path.unlink(missing_ok=True)

    target_sr = 16000
    if orig_sr != target_sr:
        ratio = orig_sr / float(target_sr)
        out_len = int(len(samples) / ratio)
        resampled: list[float] = []
        n = len(samples)
        for i in range(out_len):
            pos = i * ratio
            idx = int(pos)
            frac = pos - idx
            s0 = samples[idx]
            s1 = samples[idx + 1] if idx + 1 < n else s0
            resampled.append(s0 + (s1 - s0) * frac)
        samples = resampled

    duration_sec = len(samples) / float(target_sr)
    if duration_sec < 0.2:
        raise ValidationError(
            f"Âm thanh '{audio_path.name}' quá ngắn ({duration_sec:.2f}s < 0.20s)."
        )

    return samples, target_sr


def fft_radix2(x: list[complex]) -> list[complex]:
    """Pure-Python iterative Cooley-Tukey FFT for power-of-two lengths."""
    n = len(x)
    if n <= 1:
        return x
    # Bit-reversal permutation
    j = 0
    arr = list(x)
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            arr[i], arr[j] = arr[j], arr[i]

    size = 2
    while size <= n:
        half = size // 2
        angle_step = -2.0 * math.pi / size
        w_step = cmath.exp(1j * angle_step)
        for start in range(0, n, size):
            w = 1.0 + 0.0j
            for k in range(half):
                even = arr[start + k]
                odd = w * arr[start + k + half]
                arr[start + k] = even + odd
                arr[start + k + half] = even - odd
                w *= w_step
        size <<= 1
    return arr


def estimate_f0_yin(frame: list[float], sample_rate: int) -> float | None:
    """Estimate fundamental frequency (Hz) on one frame using YIN."""
    fmin = 65.0
    fmax = 450.0
    tau_min = max(2, int(sample_rate / fmax))
    tau_max = min(len(frame) // 2 - 2, int(sample_rate / fmin))
    if tau_max <= tau_min + 2:
        return None

    diff = [0.0] * (tau_max + 1)
    n_win = len(frame) - tau_max
    for tau in range(1, tau_max + 1):
        acc = 0.0
        for j in range(n_win):
            d = frame[j] - frame[j + tau]
            acc += d * d
        diff[tau] = acc

    cmnd = [1.0] * (tau_max + 1)
    running_sum = 0.0
    for tau in range(1, tau_max + 1):
        running_sum += diff[tau]
        if running_sum > 1e-12:
            cmnd[tau] = diff[tau] * tau / running_sum
        else:
            cmnd[tau] = 1.0

    threshold = 0.18
    tau_est = -1
    for tau in range(tau_min, tau_max):
        if cmnd[tau] < threshold:
            while tau + 1 <= tau_max and cmnd[tau + 1] < cmnd[tau]:
                tau += 1
            tau_est = tau
            break

    if tau_est < 0:
        best_tau = min(range(tau_min, tau_max + 1), key=lambda t: cmnd[t])
        if cmnd[best_tau] > 0.35:
            return None
        tau_est = best_tau

    # Parabolic interpolation around tau_est
    if 1 <= tau_est < tau_max:
        s0 = cmnd[tau_est - 1]
        s1 = cmnd[tau_est]
        s2 = cmnd[tau_est + 1]
        denom = 2.0 * (s0 - 2.0 * s1 + s2)
        if abs(denom) > 1e-12:
            tau_refined = tau_est + (s0 - s2) / denom
        else:
            tau_refined = float(tau_est)
    else:
        tau_refined = float(tau_est)

    if tau_refined <= 0.0:
        return None
    f0 = sample_rate / tau_refined
    if fmin <= f0 <= fmax:
        return f0
    return None


def analyze_audio_features(samples: list[float], sample_rate: int) -> dict[str, float]:
    """Extract acoustic pitch, spectral energy distribution, and dynamics."""
    # Remove DC offset
    mean_val = sum(samples) / len(samples)
    centered = [s - mean_val for s in samples]

    peak_amp = max((abs(s) for s in centered), default=0.0)
    if peak_amp < 1e-4:
        raise ValidationError("Âm thanh gốc quá nhỏ hoặc im lặng hoàn toàn.")
    peak_db = 20.0 * math.log10(max(peak_amp, 1e-9))

    frame_len = 512
    hop_len = 256
    frame_rms_dbs: list[float] = []
    frames: list[list[float]] = []

    for start in range(0, len(centered) - frame_len + 1, hop_len):
        fr = centered[start : start + frame_len]
        rms = math.sqrt(sum(v * v for v in fr) / frame_len)
        db = 20.0 * math.log10(max(rms, 1e-9))
        frame_rms_dbs.append(db)
        frames.append(fr)

    if not frames:
        raise ValidationError("Không đủ khung dữ liệu để phân tích âm thanh.")

    sorted_dbs = sorted(frame_rms_dbs)
    p15_idx = max(0, int(0.15 * len(sorted_dbs)))
    noise_floor_db = clamp(sorted_dbs[p15_idx], -68.0, -24.0)

    active_threshold_db = max(noise_floor_db + 6.0, sorted_dbs[-1] - 28.0)
    active_indices = [
        i for i, db in enumerate(frame_rms_dbs) if db >= active_threshold_db
    ]
    if not active_indices:
        active_indices = [i for i, db in enumerate(frame_rms_dbs) if db >= sorted_dbs[len(sorted_dbs) // 2]]

    active_samples: list[float] = []
    zcr_values: list[float] = []
    f0_estimates: list[float] = []

    # Stride through active frames for fast deterministic pitch & spectral stats
    stride = max(1, len(active_indices) // 48)
    sampled_indices = active_indices[::stride][:48]

    for idx in active_indices:
        fr = frames[idx]
        active_samples.extend(fr)
        zc = sum(
            1
            for k in range(1, len(fr))
            if (fr[k - 1] >= 0.0 and fr[k] < 0.0) or (fr[k - 1] < 0.0 and fr[k] >= 0.0)
        )
        zcr_values.append(zc / float(len(fr) - 1))

    for idx in sampled_indices:
        f0 = estimate_f0_yin(frames[idx], sample_rate)
        if f0 is not None:
            f0_estimates.append(f0)

    rms_total = math.sqrt(sum(v * v for v in active_samples) / max(1, len(active_samples)))
    rms_db = 20.0 * math.log10(max(rms_total, 1e-9))
    crest_factor_db = max(1.5, peak_db - rms_db)

    if f0_estimates:
        f0_sorted = sorted(f0_estimates)
        detected_f0_hz = f0_sorted[len(f0_sorted) // 2]
    else:
        # Fallback approximation from ZCR if purely unvoiced
        avg_zcr = sum(zcr_values) / max(1, len(zcr_values))
        detected_f0_hz = clamp(avg_zcr * sample_rate * 0.5, 95.0, 260.0)

    # 1024-pt FFT spectral balance across voiced slices
    fft_n = 1024
    hann = [0.5 - 0.5 * math.cos(2.0 * math.pi * n / (fft_n - 1)) for n in range(fft_n)]
    accum_mag = [0.0] * (fft_n // 2)
    fft_count = 0

    for idx in sampled_indices[:24]:
        start = idx * hop_len
        if start + fft_n > len(centered):
            continue
        windowed = [complex(centered[start + n] * hann[n], 0.0) for n in range(fft_n)]
        spectrum = fft_radix2(windowed)
        for k in range(1, fft_n // 2):
            accum_mag[k] += abs(spectrum[k])
        fft_count += 1

    if fft_count == 0:
        # Pad single slice if short
        slice_data = centered[:fft_n] + [0.0] * max(0, fft_n - len(centered))
        windowed = [complex(slice_data[n] * hann[n], 0.0) for n in range(fft_n)]
        spectrum = fft_radix2(windowed)
        for k in range(1, fft_n // 2):
            accum_mag[k] = abs(spectrum[k])
        fft_count = 1

    low_energy = 0.0
    mid_energy = 0.0
    high_energy = 0.0
    weighted_freq_sum = 0.0
    mag_sum = 0.0

    for k in range(1, fft_n // 2):
        freq = k * sample_rate / float(fft_n)
        mag = accum_mag[k] / fft_count
        energy = mag * mag
        if 75.0 <= freq < 350.0:
            low_energy += energy
        elif 350.0 <= freq < 2500.0:
            mid_energy += energy
        elif 2500.0 <= freq <= 7800.0:
            high_energy += energy
        if 75.0 <= freq <= 7800.0:
            weighted_freq_sum += freq * mag
            mag_sum += mag

    total_band_energy = max(1e-12, low_energy + mid_energy + high_energy)
    spectral_centroid_hz = weighted_freq_sum / max(1e-9, mag_sum)

    return {
        "duration_sec": round(len(centered) / float(sample_rate), 3),
        "sample_rate": sample_rate,
        "detected_f0_hz": round(detected_f0_hz, 2),
        "spectral_centroid_hz": round(spectral_centroid_hz, 2),
        "low_energy_ratio": round(low_energy / total_band_energy, 4),
        "mid_energy_ratio": round(mid_energy / total_band_energy, 4),
        "high_energy_ratio": round(high_energy / total_band_energy, 4),
        "rms_db": round(rms_db, 2),
        "peak_db": round(peak_db, 2),
        "noise_floor_db": round(noise_floor_db, 2),
        "crest_factor_db": round(crest_factor_db, 2),
        "zero_crossing_rate": round(sum(zcr_values) / max(1, len(zcr_values)), 4),
    }


def synthesize_dsp_params(
    features: dict[str, float],
    baseline_f0_hz: float,
    voice_cfg: dict[str, Any],
) -> dict[str, Any]:
    """Derive natural real-time DSP parameters from analyzed audio features."""
    detected_f0 = features["detected_f0_hz"]
    pitch_semitones = clamp(12.0 * math.log2(detected_f0 / baseline_f0_hz), -12.0, 12.0)

    # Estimate vocal tract formant scale from detected pitch + spectral centroid
    f0_norm = clamp((detected_f0 - 145.0) / 110.0, -0.55, 0.85)
    centroid_norm = clamp((features["spectral_centroid_hz"] - 1350.0) / 1400.0, -0.5, 0.6)
    formant_shift = clamp(1.0 + f0_norm * 0.16 + centroid_norm * 0.08, 0.78, 1.32)

    # Neutral reference spectral balance: 35% low, 45% mid, 20% high
    eq_low_db = clamp((features["low_energy_ratio"] - 0.35) * 12.0, -5.0, 5.0)
    eq_mid_db = clamp((features["mid_energy_ratio"] - 0.45) * 10.0, -4.5, 4.5)
    eq_high_db = clamp((features["high_energy_ratio"] - 0.20) * 13.0, -5.0, 5.5)

    noise_gate_db = clamp(features["noise_floor_db"] + 6.0, -56.0, -24.0)
    compressor_threshold_db = clamp(features["rms_db"] - 4.0, -30.0, -8.0)
    compressor_ratio = clamp(1.7 + (features["crest_factor_db"] - 8.0) * 0.18, 1.5, 5.5)
    limiter_ceiling_db = clamp(max(-1.8, min(-0.5, features["peak_db"] * 0.22)), -2.5, -0.4)

    raw_nat = voice_cfg.get("naturalness", 0.90)
    if not isinstance(raw_nat, (int, float)):
        raise ValidationError(f"Trường 'naturalness' ở giọng '{voice_cfg['id']}' phải là số.")
    naturalness = clamp(float(raw_nat), 0.1, 1.0)

    overrides = voice_cfg.get("dsp_overrides", {})
    if overrides is None:
        overrides = {}
    if not isinstance(overrides, dict):
        raise ValidationError(f"Trường 'dsp_overrides' ở giọng '{voice_cfg['id']}' phải là object.")

    # Adaptive F0 tracking matches any user's mic to admin's sample voice pitch unless manually overridden
    adaptive_pitch = "pitch_semitones" not in overrides

    dsp: dict[str, Any] = {
        "pitch_semitones": round(pitch_semitones, 3),
        "formant_shift": round(formant_shift, 3),
        "eq_low_db": round(eq_low_db, 2),
        "eq_mid_db": round(eq_mid_db, 2),
        "eq_high_db": round(eq_high_db, 2),
        "noise_gate_db": round(noise_gate_db, 2),
        "compressor_threshold_db": round(compressor_threshold_db, 2),
        "compressor_ratio": round(compressor_ratio, 2),
        "limiter_ceiling_db": round(limiter_ceiling_db, 2),
        "naturalness": round(naturalness, 3),
        "target_f0_hz": round(detected_f0, 2),
        "adaptive_pitch": adaptive_pitch,
    }

    for key, val in overrides.items():
        if key not in DSP_BOUNDS:
            raise ValidationError(f"Tham số override không hợp lệ '{key}' ở giọng '{voice_cfg['id']}'.")
        if not isinstance(val, (int, float)) or isinstance(val, bool):
            raise ValidationError(f"Giá trị '{key}' ở giọng '{voice_cfg['id']}' phải là số.")
        lo, hi = DSP_BOUNDS[key]
        if not (lo <= float(val) <= hi):
            raise ValidationError(
                f"Giá trị '{key}={val}' ở giọng '{voice_cfg['id']}' vượt ngưỡng [{lo}, {hi}]."
            )
        dsp[key] = round(float(val), 3)

    return dsp


def validate_config(cfg: Any, repo_root: Path) -> tuple[float, list[dict[str, Any]]]:
    if not isinstance(cfg, dict):
        raise ValidationError("admin/config.json phải là JSON object.")

    required_top = ("schema_version", "global_lock", "maintenance", "music", "voices")
    for field in required_top:
        if field not in cfg:
            raise ValidationError(f"Thiếu trường bắt buộc '{field}' trong admin/config.json.")

    if not isinstance(cfg["schema_version"], int) or isinstance(cfg["schema_version"], bool) or cfg["schema_version"] < 1:
        raise ValidationError("Trường 'schema_version' phải là số nguyên >= 1.")
    if not isinstance(cfg["global_lock"], bool):
        raise ValidationError("Trường 'global_lock' phải là boolean (true/false).")

    maint = cfg["maintenance"]
    if not isinstance(maint, dict) or not isinstance(maint.get("enabled"), bool) or not isinstance(maint.get("message"), str):
        raise ValidationError("Trường 'maintenance' phải gồm 'enabled' (bool) và 'message' (string).")

    sync_cfg = cfg.get("sync", {})
    if not isinstance(sync_cfg, dict):
        raise ValidationError("Trường 'sync' phải là object.")
    poll_sec = sync_cfg.get("poll_interval_seconds", 15)
    if not isinstance(poll_sec, int) or isinstance(poll_sec, bool) or not (5 <= poll_sec <= 300):
        raise ValidationError("Trường 'sync.poll_interval_seconds' phải là số nguyên trong [5, 300].")

    baseline = cfg.get("baseline_speaker", {})
    if not isinstance(baseline, dict):
        raise ValidationError("Trường 'baseline_speaker' phải là object.")
    baseline_f0 = baseline.get("f0_hz", 145.0)
    if not isinstance(baseline_f0, (int, float)) or isinstance(baseline_f0, bool) or not (70.0 <= float(baseline_f0) <= 320.0):
        raise ValidationError("Trường 'baseline_speaker.f0_hz' phải nằm trong [70, 320].")

    music = cfg["music"]
    for m_key in ("repo_owner", "repo_name", "branch", "playlist_path"):
        if not isinstance(music.get(m_key), str) or not music[m_key].strip():
            raise ValidationError(f"Thiếu hoặc sai kiểu 'music.{m_key}'.")
    if not isinstance(music.get("global_lock"), bool):
        raise ValidationError("Trường 'music.global_lock' phải là boolean.")
    locked_tracks = music.get("locked_track_ids", [])
    if not isinstance(locked_tracks, list) or any(not isinstance(t, str) or not t.strip() for t in locked_tracks):
        raise ValidationError("Trường 'music.locked_track_ids' phải là mảng chuỗi hợp lệ.")

    voices = cfg["voices"]
    if not isinstance(voices, list) or len(voices) == 0:
        raise ValidationError("Trường 'voices' phải là mảng không rỗng.")

    seen_ids: set[str] = set()
    validated_voices: list[dict[str, Any]] = []
    for idx, voice in enumerate(voices):
        if not isinstance(voice, dict):
            raise ValidationError(f"voices[{idx}] phải là object.")
        vid = voice.get("id")
        if not isinstance(vid, str) or not VOICE_ID_RE.match(vid):
            raise ValidationError(f"voices[{idx}].id không hợp lệ: {vid!r}")
        if vid in seen_ids:
            raise ValidationError(f"Trùng ID giọng nói: '{vid}'.")
        seen_ids.add(vid)

        name = voice.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValidationError(f"Giọng '{vid}' thiếu trường 'name'.")
        if not isinstance(voice.get("locked"), bool):
            raise ValidationError(f"Giọng '{vid}' thiếu trường boolean 'locked'.")

        source_rel = voice.get("source_audio")
        source_path = resolve_safe_path(repo_root, source_rel, f"voices[{idx}].source_audio")
        validated_voices.append({**voice, "_resolved_audio": source_path})

    return float(baseline_f0), validated_voices


def read_previous_manifest(manifest_path: Path) -> tuple[int, dict[str, Any] | None]:
    if not manifest_path.is_file():
        return 0, None
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        payload = data.get("payload") if isinstance(data, dict) else None
        if isinstance(payload, dict) and isinstance(payload.get("version"), int):
            return payload["version"], payload
    except Exception:
        return 0, None
    return 0, None


def strip_volatile_fields(payload: dict[str, Any]) -> dict[str, Any]:
    clone = dict(payload)
    clone.pop("version", None)
    clone.pop("updated_at", None)
    return clone


def main() -> int:
    parser = argparse.ArgumentParser(description="Build signed PHL Voice & Music manifest.")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Path to amthanh_dylib repository root.",
    )
    parser.add_argument(
        "--force-bump",
        action="store_true",
        help="Always increment manifest version even if payload body is unchanged.",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    config_path = repo_root / "admin" / "config.json"
    dist_dir = repo_root / "dist"
    packs_dir = dist_dir / "packs"
    manifest_path = dist_dir / "manifest.json"

    signing_secret = os.environ.get("VOICE_SIGNING_SECRET", "").strip()
    if len(signing_secret) < 12:
        print(
            "[ERROR] Thiếu hoặc khóa VOICE_SIGNING_SECRET quá ngắn (< 12 ký tự). "
            "Hãy cấu hình Repository Secret 'VOICE_SIGNING_SECRET' trên GitHub.",
            file=sys.stderr,
        )
        return 1

    try:
        raw_cfg = json.loads(config_path.read_text(encoding="utf-8"))
        baseline_f0_hz, voices = validate_config(raw_cfg, repo_root)

        now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        prev_version, prev_payload = read_previous_manifest(manifest_path)

        # Analyze all voice audio files and prepare pack JSONs in memory BEFORE touching dist/
        prepared_packs: dict[str, tuple[dict[str, Any], bytes, str]] = {}
        manifest_voices: list[dict[str, Any]] = []

        # Provisional version (adjusted if payload differs)
        next_version = max(1, prev_version + 1) if prev_version > 0 else 1

        for voice in voices:
            vid = voice["id"]
            audio_path: Path = voice["_resolved_audio"]
            samples, sr = load_audio_16k(audio_path)
            features = analyze_audio_features(samples, sr)
            dsp_params = synthesize_dsp_params(features, baseline_f0_hz, voice)

            pack_obj = {
                "schema_version": 1,
                "id": vid,
                "name": voice["name"].strip(),
                "description": str(voice.get("description", "")).strip(),
                "category": str(voice.get("category", "Chung")).strip() or "Chung",
                "locked": bool(voice["locked"]),
                "version": next_version,
                "generated_at": now_iso,
                "source_audio": voice["source_audio"].replace("\\", "/"),
                "analysis": features,
                "dsp": dsp_params,
            }

            pack_rel_path = f"dist/packs/{vid}.json"
            existing_pack_file = repo_root / pack_rel_path
            reused_existing = False

            if not args.force_bump and existing_pack_file.is_file():
                try:
                    old_pack_bytes = existing_pack_file.read_bytes()
                    old_json = json.loads(old_pack_bytes.decode("utf-8"))
                    semantic_keys = ("name", "description", "category", "locked", "source_audio", "analysis", "dsp")
                    if all(old_json.get(k) == pack_obj.get(k) for k in semantic_keys):
                        pack_sha256 = hashlib.sha256(old_pack_bytes).hexdigest()
                        prepared_packs[vid] = (old_json, old_pack_bytes, pack_rel_path)
                        reused_existing = True
                except Exception:
                    reused_existing = False

            if not reused_existing:
                pack_bytes = (json.dumps(pack_obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
                pack_sha256 = hashlib.sha256(pack_bytes).hexdigest()
                prepared_packs[vid] = (pack_obj, pack_bytes, pack_rel_path)

            manifest_voices.append(
                {
                    "id": vid,
                    "name": voice["name"].strip(),
                    "description": str(voice.get("description", "")).strip(),
                    "category": str(voice.get("category", "Chung")).strip() or "Chung",
                    "locked": bool(voice["locked"]),
                    "pack_path": pack_rel_path,
                    "pack_sha256": pack_sha256,
                }
            )

        music_cfg = raw_cfg["music"]
        payload: dict[str, Any] = {
            "schema_version": int(raw_cfg["schema_version"]),
            "version": next_version,
            "updated_at": now_iso,
            "engine_name": str(raw_cfg.get("engine_name", "PHL Voice & Music Engine")),
            "global_lock": bool(raw_cfg["global_lock"]),
            "maintenance": {
                "enabled": bool(raw_cfg["maintenance"]["enabled"]),
                "message": str(raw_cfg["maintenance"]["message"]),
            },
            "poll_interval_seconds": int(raw_cfg.get("sync", {}).get("poll_interval_seconds", 15)),
            "music": {
                "repo_owner": music_cfg["repo_owner"].strip(),
                "repo_name": music_cfg["repo_name"].strip(),
                "branch": music_cfg["branch"].strip(),
                "playlist_path": music_cfg["playlist_path"].strip(),
                "global_lock": bool(music_cfg["global_lock"]),
                "locked_track_ids": [str(t).strip() for t in music_cfg.get("locked_track_ids", [])],
            },
            "voices": manifest_voices,
        }

        if prev_payload is not None and not args.force_bump:
            if strip_volatile_fields(prev_payload) == strip_volatile_fields(payload):
                payload["version"] = prev_version

        # Write all validated pack files atomically
        packs_dir.mkdir(parents=True, exist_ok=True)
        active_pack_names: set[str] = set()
        for vid, (_, pack_bytes, pack_rel) in prepared_packs.items():
            pack_target = repo_root / pack_rel
            atomic_write_bytes(pack_target, pack_bytes)
            active_pack_names.add(pack_target.name)

        # Remove stale packs that are no longer in config.json
        for existing_file in packs_dir.glob("*.json"):
            if existing_file.name not in active_pack_names:
                existing_file.unlink()

        canonical = canonical_json_bytes(payload)
        payload_sha256 = hashlib.sha256(canonical).hexdigest()
        sig_hmac = hmac.new(
            signing_secret.encode("utf-8"),
            canonical,
            hashlib.sha256,
        ).hexdigest()
        key_fp = hashlib.sha256(
            b"PHL-KEY-FP:" + signing_secret.encode("utf-8")
        ).hexdigest()[:16]

        manifest_doc = {
            "payload": payload,
            "integrity": {
                "algorithm": "HMAC-SHA256",
                "canonical_format": "utf8-sorted-compact-json-v1",
                "payload_sha256": payload_sha256,
                "hmac_sha256": sig_hmac,
                "key_fingerprint": key_fp,
            },
        }
        atomic_write_json(manifest_path, manifest_doc)

        print(
            f"[OK] Đã xuất manifest v{payload['version']} với {len(manifest_voices)} giọng "
            f"(payload_sha256={payload_sha256[:12]}..., key_fp={key_fp})."
        )
        return 0

    except (ValidationError, json.JSONDecodeError, OSError) as exc:
        print(f"[VALIDATION FAILED] {exc}", file=sys.stderr)
        print("[SAFEGUARD] Giữ nguyên bản dist/ hợp lệ trước đó.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
