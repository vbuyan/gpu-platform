# GPU and GPU-queue metrics for node-exporter's textfile collector (ADR-010). Build from the repo root:
#   docker build -f images/gpu-queue-exporter/Dockerfile .
FROM python:3.12.15-slim
LABEL org.opencontainers.image.source="https://github.com/vbuyan/gpu-platform" \
      org.opencontainers.image.description="Textfile exporter for a shared GPU queue; never opens the GPU"
COPY gitops/monitoring/extras/gpu_queue_exporter.py /app/gpu_queue_exporter.py
USER 65534:65534
ENTRYPOINT ["python3", "-I", "/app/gpu_queue_exporter.py"]
