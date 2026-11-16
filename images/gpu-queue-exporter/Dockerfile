# GPU and GPU-queue metrics for node-exporter's textfile collector (ADR-010). Build from the repo root:
#   docker build -f images/gpu-queue-exporter/Dockerfile .
FROM python:3.12.15-slim
LABEL org.opencontainers.image.source="https://github.com/vbuyan/gpu-platform" \
      org.opencontainers.image.description="Textfile exporter for a shared GPU queue; never opens the GPU"
# the base image lags behind Debian security fixes (Trivy found 4 fixable HIGH CVEs in apt and zlib);
# take the fixes and drop pip, which the exporter never uses
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip uninstall -y pip
COPY gitops/monitoring/extras/gpu_queue_exporter.py /app/gpu_queue_exporter.py
USER 65534:65534
ENTRYPOINT ["python3", "-I", "/app/gpu_queue_exporter.py"]
