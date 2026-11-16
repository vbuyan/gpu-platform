# Whisper subtitles for GPU pods (stage 4). Build from the repo root:
#   docker build -f images/subtitles/Dockerfile .
# pip: the base image marks its Python as externally managed (PEP 668); inside an image that is fine.
# The model is not baked in: it is mounted read-only from the node (gitops/workloads/subtitles).
FROM pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime
LABEL org.opencontainers.image.source="https://github.com/vbuyan/gpu-platform" \
      org.opencontainers.image.description="Nightly Whisper subtitles through a shared GPU queue"
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --break-system-packages \
         transformers==5.2.0 accelerate==1.14.0 av==19.0.1
COPY images/subtitles/subtitles.py /app/subtitles.py
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HOME=/tmp
USER 2950:2950
ENTRYPOINT ["python", "-I", "/app/subtitles.py"]
