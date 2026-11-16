"""Tests for gpu-queue/turn against a fake dispatcher that speaks the station's protocol."""
import os
import pathlib
import socket
import subprocess
import sys
import threading

TURN = pathlib.Path(__file__).resolve().parents[1] / "gpu-queue/turn"


class FakeDispatcher:
    """Accepts one client: reads the "wait" line, reports a queue position, then grants the card."""

    def __init__(self, path, reply=("перед 1", "перед 0", "твоя")):
        self.path, self.reply = str(path), reply
        self.request, self.extra, self.released = None, [], threading.Event()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(1)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        conn, _ = self.srv.accept()
        f = conn.makefile("r", encoding="utf-8")
        self.request = f.readline().rstrip("\n")
        for line in self.reply:
            conn.sendall((line + "\n").encode())
        if not self.reply:                  # simulate a dispatcher restart: hang up without an answer
            conn.close()
            self.released.set()
            return
        for line in f:                      # anything else the client says while holding the card
            self.extra.append(line.rstrip("\n"))
        self.released.set()                 # EOF: every copy of the connection is closed


def run_turn(sock, cmd, **env):
    e = {**os.environ, "GPU_SOCK": str(sock), "PATH": "/usr/bin:/bin", **env}
    return subprocess.run([sys.executable, str(TURN), *cmd], env=e, capture_output=True, text=True, timeout=30)


def test_waits_for_turn_then_execs_with_fd9_open(tmp_path):
    d = FakeDispatcher(tmp_path / "q.sock")
    r = run_turn(d.path, ["sh", "-c", "test -S /proc/self/fd/9 || test -e /proc/self/fd/9; echo fd9=$?"],
                 GPU_WHAT="k8s test job", GPU_NEED_MB="0")
    assert r.returncode == 0, r.stderr
    assert d.request == "ждать k8s test job"
    assert "jobs ahead: 1" in r.stdout and "jobs ahead: 0" in r.stdout
    assert "fd9=0" in r.stdout               # the queue connection survived exec
    assert d.released.wait(5)                # and closed when the command exited


def test_background_flag(tmp_path):
    d = FakeDispatcher(tmp_path / "q.sock")
    r = run_turn(d.path, ["true"], GPU_FON="1", GPU_NEED_MB="0")
    assert r.returncode == 0, r.stderr
    assert d.released.wait(5)
    assert d.extra == ["фон"]


def test_refusal_is_reported(tmp_path):
    d = FakeDispatcher(tmp_path / "q.sock", reply=("ошибка не пускаю",))
    r = run_turn(d.path, ["true"])
    assert r.returncode != 0
    assert "dispatcher refused: не пускаю" in r.stderr


def test_dispatcher_hangs_up(tmp_path):
    d = FakeDispatcher(tmp_path / "q.sock", reply=())
    r = run_turn(d.path, ["true"])
    assert r.returncode != 0
    assert "closed the connection" in r.stderr


def test_no_dispatcher(tmp_path):
    r = run_turn(tmp_path / "missing.sock", ["true"])
    assert r.returncode != 0
    assert "cannot reach the GPU queue" in r.stderr
