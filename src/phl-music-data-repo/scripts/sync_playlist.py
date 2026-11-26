#!/usr/bin/env python3
"""
PHL Music Data - Playlist Validator & Auto-Sync Script
Scans tracks/ inside phl-music-data, validates playlist.json, computes sha256
and duration_sec (via ffprobe if available), auto-registers new tracks, and
writes playlist.json atomically.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUPPORTED_AUDIO_EXTS = {".mp3", ".m4a", ".aac", ".wav", ".ogg", ".flac"}
TRACK_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,79}$")


class PlaylistValidationError(Exception):
    """Raised when playlist.json or tracks directory fails validation."""


def slugify_track_id(stem: str) -> str:
    slug = re.sub(r"[^a-z0-9_-]+", "_", stem.lower()).strip("_-")
    if not slug or not slug[0].isalnum():
        slug = f"track_{slug}" if slug else "track_item"
    return slug[:72]


def humanize_title(stem: str) -> str:
    cleaned = re.sub(r"[_-]+", " ", stem).strip()
    return cleaned.title() if cleaned else "Bản Nhạc Mới"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def probe_duration_sec(path: Path) -> int:
    if path.suffix.lower() == ".wav":
        try:
            with wave.open(str(path), "rb") as wf:
                sr = wf.getframerate()
                frames = wf.getnframes()
                if sr > 0:
                    return max(1, int(round(frames / float(sr))))
        except wave.Error:
            pass

    ffprobe_bin = shutil.which("ffprobe")
    if ffprobe_bin:
        proc = subprocess.run(
            [
                ffprobe_bin,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            try:
                return max(1, int(round(float(proc.stdout.strip()))))
            except ValueError:
                pass
    return 0


def atomic_write_json(target_path: Path, data: Any) -> None:
    encoded = (json.dumps(data, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target_path.name}.",
        suffix=".tmp",
        dir=str(target_path.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(tmp_path), str(target_path))
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate & sync phl-music-data playlist.json")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Path to phl-music-data repository root.",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    playlist_path = repo_root / "playlist.json"
    tracks_dir = repo_root / "tracks"

    try:
        if playlist_path.is_file():
            raw = json.loads(playlist_path.read_text(encoding="utf-8"))
        else:
            raw = {
                "schema_version": 1,
                "version": 0,
                "updated_at": "",
                "repo": "phamlong3539-stack/phl-music-data",
                "branch": "main",
                "global_lock": False,
                "tracks": [],
            }

        if not isinstance(raw, dict):
            raise PlaylistValidationError("playlist.json phải là JSON object.")
        if not isinstance(raw.get("global_lock", False), bool):
            raise PlaylistValidationError("Trường 'global_lock' phải là boolean.")

        declared_tracks = raw.get("tracks", [])
        if not isinstance(declared_tracks, list):
            raise PlaylistValidationError("Trường 'tracks' phải là mảng.")

        seen_ids: set[str] = set()
        registered_paths: set[str] = set()
        normalized_tracks: list[dict[str, Any]] = []

        for idx, entry in enumerate(declared_tracks):
            if not isinstance(entry, dict):
                raise PlaylistValidationError(f"tracks[{idx}] phải là object.")
            tid = entry.get("id")
            if not isinstance(tid, str) or not TRACK_ID_RE.match(tid):
                raise PlaylistValidationError(f"tracks[{idx}].id không hợp lệ: {tid!r}")
            if tid in seen_ids:
                raise PlaylistValidationError(f"Trùng track ID: '{tid}'")
            seen_ids.add(tid)

            rel_fp = entry.get("file_path")
            if not isinstance(rel_fp, str) or not rel_fp.strip():
                raise PlaylistValidationError(f"Track '{tid}' thiếu 'file_path'.")
            rel_norm = rel_fp.replace("\\", "/").lstrip("/")
            if ".." in rel_norm.split("/"):
                raise PlaylistValidationError(f"Đường dẫn không an toàn: {rel_fp}")

            abs_file = (repo_root / rel_norm).resolve()
            if repo_root not in abs_file.parents or not abs_file.is_file():
                raise PlaylistValidationError(
                    f"Không tìm thấy file nhạc '{rel_norm}' cho track '{tid}'."
                )
            if abs_file.suffix.lower() not in SUPPORTED_AUDIO_EXTS:
                raise PlaylistValidationError(
                    f"Định dạng nhạc không hỗ trợ cho '{tid}': {abs_file.suffix}"
                )
            if abs_file.stat().st_size == 0:
                raise PlaylistValidationError(f"File nhạc rỗng: {rel_norm}")

            locked = entry.get("locked", False)
            if not isinstance(locked, bool):
                raise PlaylistValidationError(f"Track '{tid}' có 'locked' không phải boolean.")

            vol = entry.get("default_volume", 0.75)
            if not isinstance(vol, (int, float)) or isinstance(vol, bool) or not (0.0 <= float(vol) <= 1.0):
                raise PlaylistValidationError(f"Track '{tid}' có 'default_volume' ngoài [0.0, 1.0].")

            title = str(entry.get("title") or humanize_title(abs_file.stem)).strip()
            artist = str(entry.get("artist") or "PHL Music").strip()
            duration_sec = entry.get("duration_sec")
            if not isinstance(duration_sec, int) or duration_sec <= 0:
                duration_sec = probe_duration_sec(abs_file)

            registered_paths.add(rel_norm)
            normalized_tracks.append(
                {
                    "id": tid,
                    "title": title,
                    "artist": artist,
                    "duration_sec": duration_sec,
                    "file_path": rel_norm,
                    "file_size_bytes": abs_file.stat().st_size,
                    "sha256": file_sha256(abs_file),
                    "locked": locked,
                    "default_volume": round(float(vol), 2),
                }
            )

        # Auto-discover new audio files dropped into tracks/
        if tracks_dir.is_dir():
            for audio_file in sorted(tracks_dir.rglob("*")):
                if not audio_file.is_file() or audio_file.suffix.lower() not in SUPPORTED_AUDIO_EXTS:
                    continue
                rel_norm = audio_file.relative_to(repo_root).as_posix()
                if rel_norm in registered_paths:
                    continue
                if audio_file.stat().st_size == 0:
                    raise PlaylistValidationError(f"File nhạc mới bị rỗng: {rel_norm}")

                base_id = slugify_track_id(audio_file.stem)
                candidate_id = base_id
                suffix = 2
                while candidate_id in seen_ids:
                    candidate_id = f"{base_id}_{suffix}"
                    suffix += 1
                seen_ids.add(candidate_id)

                normalized_tracks.append(
                    {
                        "id": candidate_id,
                        "title": humanize_title(audio_file.stem),
                        "artist": "PHL Music",
                        "duration_sec": probe_duration_sec(audio_file),
                        "file_path": rel_norm,
                        "file_size_bytes": audio_file.stat().st_size,
                        "sha256": file_sha256(audio_file),
                        "locked": False,
                        "default_volume": 0.75,
                    }
                )

        prev_version = int(raw.get("version", 0))
        prev_body = {
            "global_lock": bool(raw.get("global_lock", False)),
            "tracks": raw.get("tracks", []),
        }
        new_body = {
            "global_lock": bool(raw.get("global_lock", False)),
            "tracks": normalized_tracks,
        }

        if prev_body == new_body and prev_version >= 1 and playlist_path.is_file():
            print(f"[OK] playlist.json không thay đổi (v{prev_version}, {len(normalized_tracks)} bài).")
            return 0

        new_version = max(1, prev_version + 1)
        output_doc = {
            "schema_version": 1,
            "version": new_version,
            "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "repo": "phamlong3539-stack/phl-music-data",
            "branch": "main",
            "global_lock": bool(raw.get("global_lock", False)),
            "tracks": normalized_tracks,
        }
        atomic_write_json(playlist_path, output_doc)
        print(f"[OK] Đã cập nhật playlist.json v{new_version} ({len(normalized_tracks)} bài).")
        return 0

    except (PlaylistValidationError, json.JSONDecodeError, OSError) as exc:
        print(f"[VALIDATION FAILED] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
