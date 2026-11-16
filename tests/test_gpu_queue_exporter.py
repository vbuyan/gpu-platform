"""Unit tests for the GPU-queue textfile exporter, against fixture files shaped like the station's."""
import importlib.util
import os
import pathlib
import time

import pytest

SRC = pathlib.Path(__file__).resolve().parents[1] / "gitops/monitoring/extras/gpu_queue_exporter.py"


@pytest.fixture
def exporter(tmp_path, monkeypatch):
    run = tmp_path / "run"
    run.mkdir()
    (run / "gpu.csv").write_text("5716, 59, 134.75, 37\n")
    (run / "apps.csv").write_text("93457, 436\n658690, 440\n")
    now = time.time()
    (run / "ochered").write_text(f"2|ber|{now - 600:.0f}|111|0|render\n3|purpose|{now - 60:.0f}|222|0|clip\n")
    (run / "ochered-fon").write_text(f"4|purpose|{now - 30:.0f}|333|-1|lora training\n")
    held_since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - 120))
    (tmp_path / "gpu.who").write_text(f"purpose|{held_since}|blender render|4444\n")
    recent = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - 3600))
    old = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - 3 * 86400))
    (tmp_path / "gpu.log").write_text(
        "header line that may be cut by the tail read\n"
        f"{recent}|{recent}|purpose|600|0|python3 a.py|30\n"
        f"{recent}|{recent}|purpose|300|1|python3 b.py --x|900\n"
        f"{recent}|{recent}|ber|1200|0|comfy | with a pipe in the command|45\n"
        f"{old}|{old}|ber|9999|0|too old|1\n")
    monkeypatch.setenv("GPU_RUN", str(run))
    monkeypatch.setenv("GPU_WHO", str(tmp_path / "gpu.who"))
    monkeypatch.setenv("GPU_LOG", str(tmp_path / "gpu.log"))
    monkeypatch.setenv("OUT", str(tmp_path / "out.prom"))
    spec = importlib.util.spec_from_file_location("gpu_queue_exporter", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, now


def samples(mod, now):
    out = {}
    for name, _help, _kind, rows in mod.collect(now):
        for labels, value in rows:
            out[(name, tuple(sorted(labels.items())))] = value
    return out


def test_gpu_snapshot(exporter):
    mod, now = exporter
    s = samples(mod, now)
    assert s[("station_gpu_memory_used_mib", ())] == 5716
    assert s[("station_gpu_temperature_celsius", ())] == 59
    assert s[("station_gpu_utilization_ratio", ())] == pytest.approx(0.37)
    assert s[("station_gpu_processes", ())] == 2


def test_queue_and_holder(exporter):
    mod, now = exporter
    s = samples(mod, now)
    assert s[("station_gpu_queue_waiting", (("kind", "normal"), ("owner", "ber")))] == 1
    assert s[("station_gpu_queue_waiting", (("kind", "background"), ("owner", "purpose")))] == 1
    assert s[("station_gpu_queue_oldest_wait_seconds", ())] == pytest.approx(600, abs=2)
    assert s[("station_gpu_queue_holder", (("owner", "purpose"),))] == 1
    assert s[("station_gpu_queue_holder_seconds", ())] == pytest.approx(120, abs=2)


def test_job_log_last_24h(exporter):
    mod, now = exporter
    s = samples(mod, now)
    assert s[("station_gpu_jobs_24h", (("owner", "purpose"),))] == 2
    assert s[("station_gpu_jobs_failed_24h", (("owner", "purpose"),))] == 1
    assert s[("station_gpu_busy_seconds_24h", (("owner", "purpose"),))] == 900
    assert s[("station_gpu_jobs_24h", (("owner", "ber"),))] == 1      # the 3-day-old job is ignored
    assert s[("station_gpu_max_wait_seconds_24h", (("owner", "purpose"),))] == 900


def test_missing_files_do_not_crash(tmp_path, monkeypatch, exporter):
    mod, now = exporter
    monkeypatch.setattr(mod, "RUN", str(tmp_path / "nowhere"))
    monkeypatch.setattr(mod, "LOG", str(tmp_path / "nowhere.log"))
    s = samples(mod, now)
    assert s[("station_gpu_snapshot_age_seconds", ())] == -1
    assert ("station_gpu_temperature_celsius", ()) not in s


def test_render_is_valid_exposition(exporter):
    mod, now = exporter
    text = mod.render(mod.collect(now))
    for line in text.splitlines():
        if line.startswith("#"):
            assert line.split()[1] in ("HELP", "TYPE")
        else:
            name_labels, value = line.rsplit(" ", 1)
            float(value)
            assert name_labels.startswith("station_gpu_")
    os.environ.pop("GPU_RUN", None)
