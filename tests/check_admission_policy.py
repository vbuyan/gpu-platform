#!/usr/bin/env python3
"""Admission policy test: needs a cluster with gitops/platform applied (CI uses kind).

Builds a correct GPU pod from examples/gpu-smoke-job.yaml, then breaks it in ten ways and
checks with server-side dry runs that the API server admits the first and denies the rest.
"""
import copy
import json
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
job = yaml.safe_load((ROOT / "examples/gpu-smoke-job.yaml").read_text())
GOOD = {"apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": "policy-test", "namespace": "jobs",
                     "annotations": job["spec"]["template"]["metadata"]["annotations"]},
        "spec": job["spec"]["template"]["spec"]}


def without_gpu(p):
    p["metadata"].pop("annotations")
    p["spec"].pop("runtimeClassName")
    p["spec"]["containers"][0]["command"] = ["sleep", "1"]


CASES = [  # (name, change, expect admitted)
    ("correct GPU pod", lambda p: None, True),
    ("outside namespace jobs", lambda p: p["metadata"].update(namespace="default"), False),
    ("no queue wrapper", lambda p: p["spec"]["containers"][0].update(command=["python", "-c"]), False),
    ("runs as another user", lambda p: p["spec"]["securityContext"].update(runAsUser=1000), False),
    ("container switches to root", lambda p: p["spec"]["containers"][0]["securityContext"].update(runAsUser=0), False),
    ("GPU without the queue device", lambda p: p["metadata"]["annotations"].update({"cdi.k8s.io/gpu": "nvidia.com/gpu=all"}), False),
    ("other annotation key", lambda p: p["metadata"].update(
        annotations={"cdi.k8s.io/x": "nvidia.com/gpu=all,station.local/gpu-queue=socket"}), False),
    ("second container", lambda p: p["spec"]["containers"].append(dict(p["spec"]["containers"][0], name="b")), False),
    ("annotation without runtime class", lambda p: p["spec"].pop("runtimeClassName"), False),
    ("runtime class without annotation", lambda p: p["metadata"].pop("annotations"), False),
    ("runtime class outside jobs", lambda p: (p["metadata"].pop("annotations"), p["metadata"].update(namespace="default")), False),
    ("ordinary pod in jobs", without_gpu, True),
]


def admitted(pod):
    r = subprocess.run(["kubectl", "apply", "--dry-run=server", "-f", "-"],
                       input=json.dumps(pod), capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1]


failed = 0
for name, change, expect in CASES:
    pod = copy.deepcopy(GOOD)
    change(pod)
    ok, msg = admitted(pod)
    verdict = "PASS" if ok == expect else "FAIL"
    failed += verdict == "FAIL"
    print(f"{verdict}  {name:34s} {'admitted' if ok else 'denied'}" + ("" if ok else f": {msg[-90:]}"))
print(f"{len(CASES) - failed}/{len(CASES)} cases as expected")
sys.exit(1 if failed else 0)
