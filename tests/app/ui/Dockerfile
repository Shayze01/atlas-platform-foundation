# Browser-test runner: Playwright's Ubuntu image (browsers preinstalled) pinned by digest,
# plus the Playwright Python package pinned by version and hash. Never deployed.
FROM mcr.microsoft.com/playwright/python:v1.64.1-noble@sha256:330d401ae23c905896a0c26c66c36fc971b621519e7b11b435a8328d7bf6e031
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 PIP_BREAK_SYSTEM_PACKAGES=1
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m pip install --require-hashes --no-deps --only-binary=:all: -r /tmp/requirements.txt
