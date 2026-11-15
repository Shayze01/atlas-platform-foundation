# Atlas Service Desk (demo): Flask app served by Gunicorn. Fictional data only.
# Base image pinned by digest; Python packages pinned by version and SHA-256 hash.
ARG PYTHON_IMAGE=python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

FROM ${PYTHON_IMAGE} AS deps
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt /tmp/requirements.txt
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --no-deps --only-binary=:all: -r /tmp/requirements.txt

FROM ${PYTHON_IMAGE} AS healthy
ARG REVISION=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="atlas-tickets" \
      org.opencontainers.image.description="Atlas Service Desk demo (fictional data only)" \
      org.opencontainers.image.source="https://github.com/Shayze01/atlas-platform-foundation" \
      org.opencontainers.image.revision="${REVISION}" \
      atlas.variant="healthy"
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ATLAS_DB_PATH=/var/lib/atlas-tickets/tickets.db \
    ATLAS_VARIANT=healthy \
    ATLAS_REVISION=${REVISION} \
    ATLAS_BUILD_TIME=${BUILD_TIME}
COPY --from=deps /opt/venv /opt/venv
WORKDIR /app
COPY gunicorn.conf.py wsgi.py ./
COPY atlas_tickets ./atlas_tickets
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin atlas \
 && mkdir -p /var/lib/atlas-tickets && chown atlas:atlas /var/lib/atlas-tickets
USER 10001
VOLUME ["/var/lib/atlas-tickets"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"]
CMD ["gunicorn", "--config", "gunicorn.conf.py", "wsgi:app"]
