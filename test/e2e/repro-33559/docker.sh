#!/usr/bin/env bash
# Run a demo inside the CI-mirror container: bash test/e2e/repro-33559/docker.sh <demo args...>
# First run installs dependencies and Chrome into named volumes (a few minutes; slow on Apple
# Silicon because the image is amd64 and runs under emulation).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
docker build --platform linux/amd64 -t threejs-repro-33559 "$ROOT/test/e2e/repro-33559"
exec docker run --rm --platform linux/amd64 --shm-size=2g \
  -v "$ROOT":/work \
  -v threejs-repro-33559-node_modules:/work/node_modules \
  -v threejs-repro-33559-profile:/work/.puppeteer_profile \
  -v threejs-repro-33559-chrome:/root/.cache/puppeteer \
  -w /work threejs-repro-33559 bash -c '
    [ -d node_modules/puppeteer ] || npm ci --no-audit --no-fund
    ls /root/.cache/puppeteer/chrome/*/chrome-linux64/chrome >/dev/null 2>&1 || npx puppeteer browsers install chrome
    [ -f build/three.webgpu.js ] || npm run build
    bash test/e2e/repro-33559/demo.sh "$@"' -- "$@"
