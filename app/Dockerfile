# Small, non-root nginx image that serves the Atlas landing page and /health.
ARG BASE_IMAGE=nginxinc/nginx-unprivileged:1.30-alpine
FROM ${BASE_IMAGE}

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1
