# Reproductions for issue 33559 — "CI: Tests are not consistently running with WebGPU"

This branch adds nothing to the library. It adds a few clearly-marked switches to the E2E
harness, one probe example, and a script that asserts the *buggy* behaviour, so that
`exit 0` / a green Actions job means "reproduced". Nothing here is proposed for merging as-is.

```bash
npm ci && npm run build
bash test/e2e/repro-33559/demo.sh device-lost      # any OS with a browser GPU
bash test/e2e/repro-33559/demo.sh forced-race      # any OS with a browser GPU
bash test/e2e/repro-33559/demo.sh adapter          # Linux (CI-like); informational elsewhere
bash test/e2e/repro-33559/demo.sh icd as-is        # Linux with mesa-vulkan-drivers + xvfb
bash test/e2e/repro-33559/demo.sh icd fixed
bash test/e2e/repro-33559/demo.sh icd unset
```

In GitHub Actions: push this branch to your fork and open a PR against your fork's `dev`
(or trigger `Repro 33559` from the Actions tab). Every job asserts the buggy behaviour.

No Linux box? `bash test/e2e/repro-33559/docker.sh icd as-is` runs a demo in a container
built like the CI job (Ubuntu 24.04, Node 24, mesa-vulkan-drivers 25.2.8, xvfb, headful
Chrome). Apple Silicon runs it under amd64 emulation, so expect several minutes per demo.

## 1. A WebGPU Device Lost makes the harness skip the example and report PASS

`test/e2e/puppeteer.js` catches errors containing `WebGPU Device Lost`, restarts the browser,
and continues with the *next* file; the current file is neither retried nor added to
`failedScreenshots`, yet it is still counted in the final `N screenshots rendered correctly`.

`examples/webgpu_zz_devicelost_probe.html` renders solid red, then calls
`renderer.onDeviceLost(...)` — the same entry point `WebGPUBackend` uses when `GPUDevice.lost`
resolves. Its committed baseline is a copy of `webgl_geometry_cube.jpg`, so any real diff would fail.

```
$ bash test/e2e/repro-33559/demo.sh device-lost
Error: webgpu_zz_devicelost_probe: THREE.THREE.WebGPURenderer: WebGPU Device Lost:
Restarting browser...
TEST PASSED! 2 screenshots rendered correctly.
(exit code 0)
RESULT: device-lost REPRODUCED
```

This is what the issue's opening screenshot shows (examples with no diff percentage in a
passing run). It is not currently triggering on `dev` — no Device Lost appears in the last ~70
upstream runs — because `--disable-gpu-watchdog` landed in PR 33650 and the offending examples
were added to the exception list in May 2026, not because the accounting was fixed.

## 2. Cold WebGPU init outruns the harness's network-idle gate

The harness opens its render gate after `page.goto(networkidle0)` and a further 2 s of network
silence, then allows exactly one animation frame. `webgpu_pmrem_*` (and 18 other `webgpu_*`
examples) only start their asset loads *after* `await renderer.init()`. On a cold runner
`requestAdapter` + `requestDevice` take 1–3 s (measured in Actions: iteration-1 median 0.8 s
for the adapter alone, up to 2.8 s), so the network is idle while init is still pending: the
gate opens, init finishes, the single frame renders immediately, and the HDR textures arrive
afterwards. The screenshot is blank and diffs at ~100 %.

The historical signature in upstream logs is `Diff wrong in 99.8% ... webgpu_pmrem_cubemap`
as the *first example of a shard* (2026-08-19 and 2026-08-20, both with PR 34225 present; PR
34225 fixed the variant where the late rAF request was dropped entirely). The same race was
caught once in 20 genuinely cold launches on Actions with the exact timeline below.

`demo.sh forced-race` makes it deterministic on any machine: `E2E_DELAY_INIT_MS=4000` slows
`requestAdapter` to 4 s (well past the ~3 s gate) and `E2E_ASSET_LATENCY_MS=300` disables the
HTTP cache and adds latency, as a cold runner has neither warm profile nor asset cache.

```
--- control: latency only (must pass)
[repro-33559] webgpu_pmrem_cubemap: network idle, opening render gate at 3.9s
webgpu_pmrem_cubemap: [repro-33559] frame rendered at 4030ms (webgpu init: done)
Diff 0.0% in file: webgpu_pmrem_cubemap (4.1s)
--- forced: init delayed 4 s + latency (must render a blank frame)
[repro-33559] webgpu_pmrem_cubemap: network idle, opening render gate at 3.9s
webgpu_pmrem_cubemap: [repro-33559] requestAdapter done at 5047ms adapter=apple/metal-3//
webgpu_pmrem_cubemap: [repro-33559] requestDevice done at 5049ms
webgpu_pmrem_cubemap: [repro-33559] frame rendered at 5170ms (webgpu init: done)
Error: Diff wrong in 99.8% of pixels in file: webgpu_pmrem_cubemap (5.2s)
--- forced + candidate fix E2E_WAIT_INIT=1 (must pass again)
[repro-33559] webgpu_pmrem_cubemap: network idle, opening render gate at 7.4s
Diff 0.0% in file: webgpu_pmrem_cubemap (7.6s)
RESULT: forced-race REPRODUCED
```

`E2E_WAIT_INIT=1` is a candidate fix, not a proposal: after network idle it waits for WebGPU
init to settle and then requires network idle *again*. Gating on `renderer.init()` or on the
first `requestAnimationFrame` alone would not help — the renderer requests its first frame
before the example starts loading. Alternatively the affected examples could start their
loads before `await renderer.init()`.

The `cold-sampler` job measures the natural rate with a fresh Chrome profile and a dropped OS
page cache per launch; it is informational. In an earlier 20-runner probe the race occurred in
1 of 20 genuinely cold launches (and 0 of 380 warm ones), matching the ~1-in-20 first-of-shard
failures seen upstream.

## 3. CI's WebGPU runs on SwiftShader, and the `VK_DRIVER_FILES` line is load-bearing

`puppeteer.js` sets `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`. Ubuntu
24.04's original Mesa (`24.0.5`) shipped that filename; the `25.2.8-0ubuntu0.24.04.2` update
(2026-04-21, six days after PR 33346 merged) installs `lvp_icd.json` instead, and it is what
every `ubuntu-latest` runner gets today. With the variable pointing at a missing file the
Vulkan loader finds no driver, Chrome logs `vkCreateInstance() failed: -9`, and Dawn falls
back to its bundled SwiftShader: every `requestAdapter()` in Actions reports
`google/swiftshader` (221/221 across five shards of the regular CI job on this branch's parent).

```
$ bash test/e2e/repro-33559/demo.sh adapter            # on ubuntu-latest
webgpu_pmrem_cubemap: [repro-33559] requestAdapter done at 1337ms adapter=google/swiftshader//
--- Vulkan ICDs on this machine:
lvp_icd.json
ii  mesa-vulkan-drivers:amd64 25.2.8-0ubuntu0.24.04.2
RESULT: adapter REPRODUCED
```

Do **not** simply "fix" the path. `demo.sh icd fixed` (points at the real `lvp_icd.json`) and
`demo.sh icd unset` (removes the variable, so the loader finds the ICD by itself) both make
Chrome's compositor come up on Vulkan/llvmpipe while Dawn *still* selects SwiftShader — there
is no `--use-webgpu-adapter` in the launch flags — and the WebGPU swap chain can no longer be
backed (`Attempt to read from an uninitialized SharedImage`): every WebGPU capture is blank.

```
$ bash test/e2e/repro-33559/demo.sh icd unset          # on ubuntu-latest
webgpu_pmrem_cubemap: [repro-33559] requestAdapter done at 263ms adapter=google/swiftshader//
Attempt to read from an uninitialized SharedImage. Initialized region: (0, 0, 0, 0) Size: (800, 500)
Error: Diff wrong in 100.0% of pixels in file: webgpu_pmrem_cubemap (4.9s)
RESULT: icd REPRODUCED
```

So the E2E suite has been validating WebGPU on SwiftShader since the Lavapipe migration, the
committed WebGPU baselines match SwiftShader output, and the misnamed path is currently what
keeps the compositor off Vulkan. Whatever the intended configuration is, it should be made
explicit (e.g. drop `--enable-features=Vulkan` and the Mesa install together, and assert the
adapter identity per shard) rather than depending on a filename mismatch.

## What is in this branch

- `test/e2e/deterministic-injection.js` — logs `adapter.info`, tracks WebGPU init state, honours `E2E_DELAY_INIT_MS`.
- `test/e2e/puppeteer.js` — env switches `E2E_ICD`, `E2E_DELAY_INIT_MS`, `E2E_ASSET_LATENCY_MS`, `E2E_WAIT_INIT`, `E2E_DUMPIO`; logs when the render gate opens; prints the previously silent "Render timeout exceeded" case.
- `examples/webgpu_zz_devicelost_probe.html` (+ deliberately wrong baseline, + `files.json` entry).
- `test/e2e/repro-33559/` — this file, `INVESTIGATION.md` (the full record: methods, evidence, corrections, open questions), `demo.sh`, `Dockerfile`, `docker.sh`.
- `.github/workflows/repro-33559.yml`.
