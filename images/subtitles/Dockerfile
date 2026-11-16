# Whisper subtitles for GPU pods (stage 4). Build from the repo root:
#   docker build -f images/subtitles/Dockerfile .
# pip: the base image marks its Python as externally managed (PEP 668); inside an image that is fine.
# The model is not baked in: it is mounted read-only from the node (gitops/workloads/subtitles).
FROM pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime
LABEL org.opencontainers.image.source="https://github.com/vbuyan/gpu-platform" \
      org.opencontainers.image.description="Nightly Whisper subtitles through a shared GPU queue"
# Trivy blocked this image three times on critical CVEs in packages that ship with the base (2026-11-16):
# Pillow 12.3.0 (8 CVEs), then certifi, uv and pip's vendored certifi bundling a CA store with
# compromised keys. Upgrade what the job uses, remove what it never needs at run time (uv, pip),
# and print every certifi copy left for the build log.
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --break-system-packages \
         transformers==5.2.0 accelerate==1.14.0 av==19.0.1 \
         pillow==13.0.0 certifi==2026.10.18 \
    && (python -m pip uninstall -y --break-system-packages uv || true) \
    && rm -f "$(command -v uv)" "$(command -v uvx)" \
    && python -m pip uninstall -y --break-system-packages pip \
    && (apt-get purge -y --auto-remove python3-pip || true) \
    && rm -rf /usr/lib/python3/dist-packages/pip /usr/lib/python3/dist-packages/pip-*.dist-info \
    && find / -xdev -path "*-packages/*" -name "certifi*" -prune 2>/dev/null
COPY images/subtitles/subtitles.py /app/subtitles.py
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HOME=/tmp
USER 2950:2950
ENTRYPOINT ["python", "-I", "/app/subtitles.py"]
