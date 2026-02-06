FROM python:3.11-slim

LABEL maintainer="vault-admin"
LABEL description="Vault Unsealer for Kubernetes"

# Install minimal dependencies
RUN pip install --no-cache-dir \
    requests==2.31.0 \
    urllib3==2.0.7

# Create app directory
WORKDIR /app

# Copy application
COPY vault-k8s-unsealer.py /app/vault-unsealer.py
RUN chmod +x /app/vault-unsealer.py

# Create non-root user
RUN useradd -r -u 1000 -g root vault-unsealer && \
    chown -R vault-unsealer:root /app

USER vault-unsealer

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python3 -c "import sys; sys.exit(0)"

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/vault-unsealer.py"]
CMD ["--help"]
