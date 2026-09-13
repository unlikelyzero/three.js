# Local mirror of the e2e CI job (ubuntu-latest, Node 24, mesa-vulkan-drivers + xvfb) for the
# Linux-only demos. Build and run via docker.sh in this directory.
FROM --platform=linux/amd64 ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git unzip xvfb mesa-vulkan-drivers vulkan-tools \
      libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2t64 \
      libpango-1.0-0 libcairo2 libxshmfence1 libx11-xcb1 libxcb-dri3-0 libgtk-3-0 \
      libxss1 libxtst6 fonts-liberation libvulkan1 \
 && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
