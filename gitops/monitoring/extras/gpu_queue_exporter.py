#!/usr/bin/env python3
"""GPU and GPU-queue metrics for node-exporter's textfile collector.

Runs as a sidecar of node-exporter and rewrites /textfile/gpu_queue.prom every 15 s.
It never touches the GPU: NVML as root would reset the device permissions the queue relies on
(ADR-009), so it reads what the station's queue services already publish:
  /run/gpu/gpu.csv       nvidia-smi snapshot by gpu-dostup: used MiB, temp C, power W, util %
  /run/gpu/apps.csv      processes on the GPU: pid, used MiB
  /run/gpu/ochered       waiting jobs:  n|owner|since|pid|prio|label   (ochered-fon: night background)
  /srv/gpu.who           current holder: owner|since|label|pid
  /srv/gpu.log           finished jobs:  start|end|owner|secs|rc|cmd|waited
"""
import os
import time
from collections import defaultdict

OUT = os.environ.get("OUT", "/textfile/gpu_queue.prom")
RUN = os.environ.get("GPU_RUN", "/host/run/gpu")
WHO = os.environ.get("GPU_WHO", "/host/srv/gpu.who")
LOG = os.environ.get("GPU_LOG", "/host/srv/gpu.log")
VRAM_TOTAL_MIB = os.environ.get("VRAM_TOTAL_MIB")   # card size, set in the deployment
EVERY = int(os.environ.get("EVERY_S", "15"))
TAIL_BYTES = 2_000_000   # the job log grows forever; 2 MB covers well over a day


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")[:80]


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def collect(now):
    m = []   # (name, help, type, [(labels, value)])

    def add(name, help_, kind, samples):
        m.append((name, help_, kind, samples))

    snap = read(f"{RUN}/gpu.csv")
    try:
        age = now - os.stat(f"{RUN}/gpu.csv").st_mtime
    except OSError:
        age = float("inf")
    add("station_gpu_snapshot_age_seconds", "Age of the nvidia-smi snapshot written by gpu-dostup.",
        "gauge", [({}, age if age != float("inf") else -1)])
    if snap:
        try:
            used, temp, power, util = (float(x) for x in snap.strip().split(","))
            add("station_gpu_memory_used_mib", "VRAM in use.", "gauge", [({}, used)])
            if VRAM_TOTAL_MIB:
                add("station_gpu_memory_total_mib", "VRAM size.", "gauge", [({}, float(VRAM_TOTAL_MIB))])
            add("station_gpu_temperature_celsius", "GPU temperature.", "gauge", [({}, temp)])
            add("station_gpu_power_watts", "GPU power draw.", "gauge", [({}, power)])
            add("station_gpu_utilization_ratio", "GPU utilization 0..1.", "gauge", [({}, util / 100)])
        except ValueError:
            pass
    apps = read(f"{RUN}/apps.csv") or ""
    add("station_gpu_processes", "Processes holding VRAM.", "gauge",
        [({}, sum(1 for line in apps.splitlines() if line.strip()))])

    waiting = defaultdict(int)
    oldest = 0.0
    for name, kind in (("ochered", "normal"), ("ochered-fon", "background")):
        for line in (read(f"{RUN}/{name}") or "").splitlines():
            parts = line.split("|")
            if len(parts) < 3:
                continue
            waiting[(parts[1], kind)] += 1
            try:
                oldest = max(oldest, now - float(parts[2]))
            except ValueError:
                pass
    add("station_gpu_queue_waiting", "Jobs waiting for the GPU.", "gauge",
        [({"owner": o, "kind": k}, n) for (o, k), n in sorted(waiting.items())] or [({"owner": "none", "kind": "normal"}, 0)])
    add("station_gpu_queue_oldest_wait_seconds", "How long the oldest waiting job has waited.", "gauge", [({}, oldest)])

    who = (read(WHO) or "").strip().split("|")
    holder, held = "none", 0.0
    if len(who) >= 2 and who[0]:
        holder = who[0]
        try:
            held = now - time.mktime(time.strptime(who[1], "%Y-%m-%d %H:%M:%S"))
        except ValueError:
            pass
    add("station_gpu_queue_holder", "Who holds the GPU now (1 for the holder).", "gauge", [({"owner": holder}, 1)])
    add("station_gpu_queue_holder_seconds", "How long the current holder has held the GPU.", "gauge", [({}, held)])

    busy, jobs, failed, waited = defaultdict(float), defaultdict(int), defaultdict(int), defaultdict(float)
    try:
        with open(LOG, "rb") as f:
            f.seek(max(0, os.path.getsize(LOG) - TAIL_BYTES))
            lines = f.read().decode("utf-8", "replace").splitlines()[1:]
    except OSError:
        lines = []
    for line in lines:
        p = line.split("|")
        if len(p) < 6:
            continue
        try:
            end = time.mktime(time.strptime(p[1], "%Y-%m-%d %H:%M:%S"))
        except ValueError:
            continue
        if now - end > 86400:
            continue
        owner = p[2]
        jobs[owner] += 1
        busy[owner] += float(p[3] or 0)
        if p[4] not in ("0", ""):
            failed[owner] += 1
        if len(p) >= 7 and p[-1].isdigit():
            waited[owner] = max(waited[owner], float(p[-1]))
    owners = sorted(set(jobs) | {o for o in os.environ.get("GPU_QUEUE_OWNERS", "").split(",") if o})
    add("station_gpu_jobs_24h", "Finished GPU jobs in the last 24 h.", "gauge", [({"owner": o}, jobs[o]) for o in owners])
    add("station_gpu_jobs_failed_24h", "GPU jobs with a non-zero exit code in the last 24 h.", "gauge",
        [({"owner": o}, failed[o]) for o in owners])
    add("station_gpu_busy_seconds_24h", "GPU time used in the last 24 h.", "gauge", [({"owner": o}, busy[o]) for o in owners])
    add("station_gpu_max_wait_seconds_24h", "Longest queue wait in the last 24 h.", "gauge", [({"owner": o}, waited[o]) for o in owners])
    return m


def render(metrics):
    out = []
    for name, help_, kind, samples in metrics:
        out.append(f"# HELP {name} {help_}")
        out.append(f"# TYPE {name} {kind}")
        for labels, value in samples:
            lab = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
            out.append(f"{name}{{{lab}}} {value:g}" if lab else f"{name} {value:g}")
    return "\n".join(out) + "\n"


def main():
    while True:
        text = render(collect(time.time()))
        tmp = OUT + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, OUT)   # node-exporter never sees a half-written file
        time.sleep(EVERY)


if __name__ == "__main__":
    main()
