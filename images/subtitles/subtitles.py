#!/usr/bin/env python3
"""Subtitles for the channels' videos, made at night on the shared GPU.

Every audio or video file in INBOX without a matching .srt in OUTBOX gets subtitles from
Whisper large-v3-turbo. Runs inside a GPU pod after /opt/gpu-queue/turn has won the card.
  subtitles.py            transcribe everything pending
  subtitles.py --pending  exit 0 if there is work, 1 if not
With an empty inbox the job still takes one short background turn at night and returns the card
within seconds, before loading the model.
Known weakness (seen in earlier runs on this host): Whisper sometimes drops or mangles numbers; the .txt
next to each .srt makes them quick to check against the script.
"""
import os
import pathlib
import sys
import time

INBOX = pathlib.Path(os.environ.get("MEDIA_IN", "/media/inbox"))
OUTBOX = pathlib.Path(os.environ.get("MEDIA_OUT", "/media/outbox"))
MODEL = os.environ.get("MODEL_DIR", "/models/whisper-large-v3-turbo")
LANGUAGE = os.environ.get("LANGUAGE", "en")          # "auto" lets Whisper detect it
SETTLE_S = int(os.environ.get("SETTLE_S", "60"))      # skip files still being copied
EXTENSIONS = {".mp4", ".mov", ".mkv", ".webm", ".m4a", ".mp3", ".wav", ".flac", ".ogg"}
RATE = 16000


def pending(now=None):
    now = time.time() if now is None else now
    if not INBOX.is_dir():
        return []
    files = []
    for f in sorted(INBOX.iterdir()):
        if f.suffix.lower() not in EXTENSIONS or not f.is_file():
            continue
        if now - f.stat().st_mtime < SETTLE_S:
            continue
        if (OUTBOX / (f.stem + ".srt")).exists():
            continue
        files.append(f)
    return files


def srt_time(seconds):
    ms = int(round(max(seconds, 0.0) * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def to_srt(chunks):
    """Whisper pipeline chunks -> SRT text. Empty texts are dropped, a missing end gets 2 s."""
    out, n = [], 0
    for c in chunks:
        text = " ".join(c.get("text", "").split())
        if not text:
            continue
        start, end = c.get("timestamp", (0.0, None))
        start = start or 0.0
        end = end if end is not None and end > start else start + 2.0
        n += 1
        out.append(f"{n}\n{srt_time(start)} --> {srt_time(end)}\n{text}\n")
    return "\n".join(out)


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def decode(path):
    """Any audio or video -> 16 kHz mono float32 (PyAV, no ffmpeg binary needed)."""
    import av
    import numpy as np
    parts = []
    with av.open(str(path)) as box:
        stream = next(s for s in box.streams if s.type == "audio")
        resampler = av.AudioResampler(format="flt", layout="mono", rate=RATE)
        for frame in box.decode(stream):
            for out in resampler.resample(frame):
                parts.append(out.to_ndarray().reshape(-1))
        for out in resampler.resample(None):
            parts.append(out.to_ndarray().reshape(-1))
    return np.concatenate(parts) if parts else np.zeros(0, dtype="float32")


def main(argv):
    todo = pending()
    if "--pending" in argv:
        print(f"subtitles: {len(todo)} file(s) pending in {INBOX}", flush=True)
        return 0 if todo else 1
    if not todo:
        print("subtitles: nothing to do", flush=True)
        return 0

    import torch
    from transformers import pipeline
    t0 = time.time()
    asr = pipeline("automatic-speech-recognition", model=MODEL, dtype=torch.float16, device="cuda:0")
    print(f"subtitles: model loaded in {time.time() - t0:.0f} s; {len(todo)} file(s)", flush=True)
    kwargs = {"task": "transcribe"}
    if LANGUAGE != "auto":
        kwargs["language"] = LANGUAGE
    OUTBOX.mkdir(parents=True, exist_ok=True)
    failed = 0
    for f in todo:
        t = time.time()
        try:
            audio = decode(f)
            result = asr({"raw": audio, "sampling_rate": RATE}, return_timestamps=True,
                         chunk_length_s=30, batch_size=8, generate_kwargs=kwargs)
        except Exception as e:  # one bad file must not stop the batch
            failed += 1
            print(f"subtitles: FAILED {f.name}: {e}", flush=True)
            continue
        write_atomic(OUTBOX / (f.stem + ".txt"), result["text"].strip() + "\n")
        write_atomic(OUTBOX / (f.stem + ".srt"), to_srt(result.get("chunks", [])))
        dur = len(audio) / RATE
        took = time.time() - t
        print(f"subtitles: {f.name}: {dur:.0f} s of audio in {took:.0f} s ({dur / max(took, 1e-6):.0f}x realtime), "
              f"{len(result.get('chunks', []))} lines", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
