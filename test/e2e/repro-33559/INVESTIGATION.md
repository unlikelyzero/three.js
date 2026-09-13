# Investigation record — issue 33559, "CI: Tests are not consistently running with WebGPU"

Work carried out 2026-09-12/13 against `dev` @ `15f789f358`. This file is the complete record:
what was checked, how, what was found, what turned out to be wrong, and what is still open.
`README.md` in this directory is the short version with the runnable reproductions.

## 1. Method

1. **Code reading**: `test/e2e/puppeteer.js`, `test/e2e/deterministic-injection.js`,
   `src/renderers/common/Renderer.js` (`init`, `_onDeviceLost`, `setAnimationLoop`),
   `src/renderers/common/Animation.js`, `src/renderers/webgpu/WebGPUBackend.js`,
   `src/nodes/math/ConditionalNode.js`, `src/nodes/pmrem/PMREMUtils.js`, the four
   `examples/webgpu_pmrem_*.html`, `.github/workflows/ci.yml`, and the history of the harness
   (`git log`/`git show` at the commits that were `dev` when each historical failure ran).
2. **Real CI log corpus** (upstream `mrdoob/three.js`, via `gh run view --log`): 11 `dev`
   runs 2026-06-03 → 2026-09-07 and 60 pull-request runs 2026-08-16 → 2026-08-21 (71 files,
   68 unique runs, 318 shard jobs that emitted results, ~35,500 example results). Only the
   `E2E testing` job lines were kept. One run (`32381512265`, branch `puppeteer-faster`,
   a harness rewrite with concurrent tabs) is excluded from all statistics.
3. **Local mirror of the CI job** (Docker, amd64 Ubuntu 24.04, Node 24,
   `mesa-vulkan-drivers 25.2.8-0ubuntu0.24.04.2`, xvfb, headful Chrome 152.0.7977.75 from
   puppeteer 25.8.0) — `Dockerfile` / `docker.sh` here. Pitfalls hit: the image needs
   `unzip` for puppeteer's Chrome download; a stale `SingletonLock` in a reused profile makes
   launches fail with "Code: 21"; headless Chrome has no `navigator.gpu`, so `VISIBLE=1`
   (headful under xvfb) is required to match CI; GitHub's default `CI=true` is parsed by the
   harness as a shard index (`parseInt('true')` → `NaN` → empty file list → "TEST PASSED! 0
   screenshots"), so probes must run with `CI` unset.
4. **Real GitHub Actions on a fork** (`unlikelyzero/three.js`, Actions enabled for this):
   instrumented copies of the regular `CI` workflow plus purpose-built probe workflows.
   Run IDs: `34714168248` (regular CI, 5 shards, adapter-identity diagnostics),
   `34714168242` (5 runners × 20 launches + device-lost job), `34714510065` (20 runners × 20
   launches with `drop_caches`, Chrome stderr captured), `34735417930` / `34735493585` /
   `34735701384` (the `Repro 33559` workflow on this branch; the last two fully green).
5. **Adversarial review of the findings** (2 Codex/GPT, 3 Claude Opus, 1 Gemini/agy
   reviewers; independent first pass, then each re-reviewed with everyone else's findings;
   every checkable dispute settled by running the command, not by majority). Its corrections
   are folded into the statuses below.
6. **Mesa package archaeology**: `apt-get download` of `mesa-vulkan-drivers=24.0.5-1ubuntu1`
   (Ubuntu 24.04 release) and `25.2.8-0ubuntu0.24.04.2` (current noble-updates/security),
   `dpkg -c` to compare the shipped ICD filenames, `changelog.Debian.gz` for dates.

## 2. Findings (final status after review)

### F1 — A WebGPU Device Lost makes the harness skip the example and report PASS. **Confirmed.**

`puppeteer.js` `checkFile()` catch block: if the error text contains `WebGPU Device Lost`, it
logs, `ctx.restart()`s (SIGKILL Chrome, relaunch) and returns; the file is neither retried nor
pushed to `failedScreenshots`, but `files.length` still counts it in
`TEST PASSED! N screenshots rendered correctly`. This is what the issue's opening screenshot
shows and what Mugen87 proposed fixing with a retry policy.

Evidence: reproduced on macOS, in the Docker mirror, and in the real `CI` workflow on the fork
(shard 4: `Device Lost` → `Restarting browser...` → `TEST PASSED! 111 screenshots`, job green)
with a probe example whose committed baseline is deliberately a copy of another example's
screenshot. `demo.sh device-lost`.

Qualifications from review: the probe calls `renderer.onDeviceLost()` (the same entry point
`WebGPUBackend` calls when `GPUDevice.lost` resolves), so it proves the accounting path, not
recovery from a real lost GPU. `page.error` is last-error-wins (`puppeteer.js`
`pageerror`/`console` handlers), so a real loss followed by another page error would be
routed to ordinary failure instead. Zero Device Lost in the 68-run corpus is *unobservable*
rather than "dormant": `--disable-gpu-watchdog` landed in PR 33650 (2026-05-27) and the two
examples named in the issue (`webgpu_compute_cloth`, `webgpu_compute_particles_fluid`) were
added to the exception list on 2026-05-15, both before the earliest surviving log.

### F2 — CI's WebGPU runs on SwiftShader; the `VK_DRIVER_FILES` line is stale and load-bearing. **Confirmed; causal story corrected.**

- `puppeteer.js` sets `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`
  (added by PR 33346, 2026-04-15, "Replace SwiftShader with software Dawn (Lavapipe)").
- Ubuntu 24.04's release Mesa `24.0.5-1ubuntu1` ships `icd.d/lvp_icd.x86_64.json`; the
  `25.2.8-0ubuntu0.24.04.2` update (changelog 2026-04-21) ships `icd.d/lvp_icd.json`. All
  329 runner setups in the corpus install 25.2.8. With the variable naming a missing file the
  Vulkan loader finds no driver (`vulkaninfo`: "Failed to open JSON file … Found no
  drivers!"), Chrome's GPU process logs `vkCreateInstance() failed: -9` / `Failed to create
  and initialize Vulkan implementation`, and Dawn uses its bundled SwiftShader.
- Every `navigator.gpu.requestAdapter()` in real Actions reported vendor `google`,
  architecture `swiftshader`: 221/221 across five shards of the regular CI job (and 101/101,
  400/400 in the probes — earlier "201/201" and "800/800" figures double-counted a log
  replay).
- The committed WebGPU baselines diff at 0.0 % against SwiftShader output (all four
  `webgpu_pmrem_*`, cold and warm, in the mirror).
- **Fixing the path does not give Lavapipe.** With the real ICD (`E2E_ICD=fixed`) *or* the
  variable removed (`E2E_ICD=unset`, Mesa still installed) Chrome's compositor comes up on
  Vulkan/llvmpipe (`chrome://gpu` shows `GaneshVulkan`), Dawn **still** selects SwiftShader
  (there is no `--use-webgpu-adapter` flag; `--enable-features=Vulkan` only affects the Viz
  compositor), and the WebGPU swap chain cannot be backed (`Attempt to read from an
  uninitialized SharedImage`): every WebGPU capture is blank. Removing the variable *and* the
  Mesa package returns to the passing SwiftShader state. Reproduced by four independent runs
  (mine, two Opus reviewers, agy) and in Actions (`demo.sh icd fixed|unset`).
- Consequences: the "Lavapipe migration" never happened on any ICD path, so PR 33346's
  premise did not hold, and PR 33650's attribution of the May device-loss crashes to "a
  limitation of Lavapipe" was unfounded (its gain is at least as well explained by the
  `--disable-gpu-watchdog` flag and the exclusion it added in the same commit).
- **Retracted**: my earlier inference that Device Lost errors "vanished because the Mesa
  update silently switched CI from Lavapipe to SwiftShader" — there was no such transition.

### F3 — Cold WebGPU init can outrun the network-idle render gate. **Confirmed as a mechanism; historical attribution narrowed.**

Mechanism: the harness opens its render gate after `page.goto(networkidle0)` + 2 s of network
silence (+ `cleanPage`, a `_videosReady` wait and a `pageSize` sleep on current `dev`), then
services animation-frame requests once. `Renderer.init()` calls `Animation.start()` (which
requests the first rAF) *before* resolving, and `webgpu_pmrem_cubemap` (and 18 other
`webgpu_*` examples: 19 of 232 load after `await renderer.init()`) only start their asset loads
after `init()` resolves. On a cold runner adapter+device creation takes ~1–3 s, so the network
is idle while init is pending; the gate opens; init finishes; the frame renders immediately;
the assets arrive afterwards; the screenshot is blank.

Evidence:
- Upstream logs: four failures with the "~100 % diff at 8.0–8.3 s" (render-timeout)
  signature — `webgpu_animation_retargeting` 2026-07-18, `webgpu_pmrem_equirectangular`
  2026-08-07, `webgpu_pmrem_cubemap` 2026-08-19 and 2026-08-20 — and all four were the
  *first example of their shard*. The two August ones ran with PR 34225 present (merge bases
  `09860b8ff9…`, `16e7674dbc…` both contain `c57d5d27df`). Pooled over the corpus: 4 blank
  failures in 324 first-slot results vs 7 in 35,221 later results.
- PR 34225 (2026-08-13) fixed the variant where a rAF requested after the gate was dropped
  entirely (blank + render timeout). The residual variant renders a frame ~100 ms after init.
- Real Actions, 20 runners × 20 launches with the OS page cache dropped: one failure, on a
  runner's first launch, with this timeline: `goto networkidle0 done 1.0s` →
  `requestAdapter done 1996ms` → `waitForNetworkIdle done 3.0s` → gate open 3048 ms →
  `requestDevice done 3162ms` → rAF requested 3163 ms → frame 3268 ms →
  `Diff wrong in 99.8%`. Because the Chrome profile was reused across iterations, only the
  20 first launches were genuinely cold (iteration-1 adapter median 804 ms vs 50 ms after),
  so the natural rate is ~1/20 cold launches, consistent with upstream's ~4/70 first-of-shard.
  A later sampler with a fresh profile per launch but a warm page cache saw 0/50 (adapter
  ready at p50 388 ms): the cost is the cold OS cache, and the race is a tail event.
- `demo.sh forced-race` makes it deterministic (`E2E_DELAY_INIT_MS=4000`,
  `E2E_ASSET_LATENCY_MS=300`): control passes, forced run blanks at 99.8 %, and
  `E2E_WAIT_INIT=1` (wait for init, then require network idle again) passes. All four
  `webgpu_pmrem_*` examples blank under the forced run.

Corrections from review: "every ~100 % failure was first on its shard" was false as a
universal — 11 such failures exist in the corpus, 7 non-first: five are the 301 s family (F4)
and two are `webgpu_xr_media_layer` on a PR that changed that example. "n=58 non-first passes,
max 3.6 s" was built from successes only (54 non-first passes + 3 non-first 98.4 % failures
from F4). Gating on `init()` or on the first rAF request alone would *not* fix the race — the
first rAF precedes the first asset request; the fix must re-establish quiescence after init,
or the examples must start loading before `await renderer.init()`. The rAF shim does not
render "exactly one frame": every rAF registered before the gate fires (2–3 callbacks seen),
and `_renderFinished` is set before the callback runs. The blank signature is not unique to
this race (F2's swap-chain failure and F4 produce the same picture), so a >90 %-diff
diagnostic dump is needed before any single attribution is airtight.

### F4 — The 300 s stalls were a separate, already-fixed harness defect. **Confirmed (found by review).**

The `dev` harness until 2026-09-06 had
`if ( e.includes && e.includes( 'Render timeout exceeded' ) === false ) throw …`. A puppeteer
`TimeoutError` object has no `.includes`, so a 5-minute `waitForNetworkIdle` timeout
(`networkTimeout = 5`) was swallowed, `page.evaluate` never set `_renderStarted`, no frame
rendered, and a blank canvas was diffed normally — exactly the `300.7 / 301.1 / 301.6 s`
durations in the corpus. `webgl_worker_offscreencanvas` passed after 300.7 s because its
worker renders regardless; the two examples after it on the same shard were blank at ~301 s
(`webgpu_animation_retargeting` 98.4 %, `_readyplayer` 97.4 %, on two unrelated PRs). PR
34474 (`7d7f2514f7`) changed the guard to `e !== 'Render timeout exceeded'`, after the whole
corpus. What wedges network idle after the worker example is not identified from logs.

### F5 — Observability gaps in the harness. **Confirmed.**

- `Render timeout exceeded` logging is commented out (`// TODO: fix this`) while the
  screenshot proceeds, which is why the four historical 8 s failures are indistinguishable
  from fast renders in the logs. (Enabled on this branch.)
- `page.on('response')` compares `response.status === 200` where `status` is a method, so
  `page.pageSize` stays 0 and the "parse time" sleep never applies; fixing it would add a real
  delay before the gate for asset-heavy pages (a partial mitigation of F3).
- No response status/URL or `requestfailed` logging, so an HTTP 429 from
  `raw.githubusercontent.com` (Mugen87's last comment) cannot be observed at all.
- `WebGPURenderer` falls back to `WebGLBackend` behind a `warn()` that the harness prints as
  non-fatal yellow, so an example can pass on WebGL2 without any assertion noticing.
- `page.error` is last-error-wins.
- `CI` env parsed with `parseInt`; the real job overrides GitHub's `CI=true` with the matrix
  index, so this only bites ad-hoc workflows.

### F6 — Other failure classes in the corpus (not part of the issue's mechanism)

`webgpu_mesh_batch` 26.2 % (2026-07-23); `webgpu_shadowmap_array` 0.2 % and
`misc_exporter_usdz` 0.2 % against the 0.1 % threshold; `webgpu_xr_media_layer` 99.0 % and
`webgpu_loader_materialx` ~17 % on PRs that changed those examples; `webgpu_gaussian_splat*`
2.0 % on the PR adding it. Ordinary nondeterminism / PR content, listed for completeness.

## 3. Hypotheses checked and set aside

- **"Divergent `If()` inside `Loop()` re-creates the PR 33650 hazard."** Untested, not
  refuted: PR 33650 added `.uniformFlow()` so `select()` compiles to a ternary instead of an
  `if/else`, i.e. the branch form is the hazardous one and `If()` emits exactly that
  (`PMREMUtils.js` `ggxConvolution` has one inside a 256-iteration loop). But every pass rate
  in the corpus was measured on SwiftShader, so nothing here exercises Lavapipe. (My first
  write-up had this argument inverted.)
- **Remote-asset 429s.** Six examples fetch from `raw.githubusercontent.com`; three are
  already excluded. Zero logged occurrences — vacuous, see F5.
- **GPU-completion race before `page.screenshot()`.** Cannot be refuted by "the failures
  are blank, not partial"; nothing observes submission/presentation. Unproven either way.
- **CPU contention between the five shards.** Each matrix job is its own VM.
- **`numCIJobs` vs matrix mismatch.** None (5 = 5).
- **Inspector's `Force WebGL` localStorage setting** (WestLangley's thread comment): a local
  browser-profile effect, not a CI mechanism.
- **`requiredFeatures` requesting every adapter feature.** Untested; the harness already
  patches `trackTimestamp` off for the E2E build, which shows the "advertised ≠ robust"
  concern is real for timestamp queries, but no evidence links other features to failures.
- **Chrome's `--disable-gpu-watchdog` no longer covering Dawn-level loss.** Not tested; no
  Device Lost occurred in 68 runs to examine.

## 4. Open questions

1. Why does Dawn select SwiftShader when a valid llvmpipe ICD is present? (Probably Chrome's
   adapter policy for CPU adapters; `--use-webgpu-adapter` was never tried.) A real Lavapipe
   WebGPU configuration would need this answered and the swap-chain backing to work.
2. What keeps network idle from settling after `webgl_worker_offscreencanvas` (F4)? Now
   surfaces as a hard "Error happened while rendering" instead of a blank.
3. The two post-34225 8.0 s failures were not reproduced; they need init to be unfinished
   ~8 s after the gate (or a GPU-process restart). Only the observability changes in F5 will
   tell the next time.
4. Whether the ~20 `webgpu_*` exception-list entries ("Black screen", "Timming issues?")
   are instances of F1–F4 rather than genuine rendering differences.
5. Whether the May 2026 Device Lost errors happened on SwiftShader (as the ICD evidence
   implies) — the logs have expired.

## 5. Recommendations that survived review (ordered)

1. Make failures observable first: enable the render-timeout log; append-only `page.error`;
   log `adapter.info` and the initialised backend per shard and fail if it is not WebGPU;
   log response status/URL and request failures; on any >90 % diff dump whether a frame
   executed, when init resolved and what was still loading.
2. Device Lost: retry the same example on a fresh page at most twice, then fail it (this
   reverses PR 33346's deliberate removal of `numAttempts`; re-acquire `ctx.page` after
   restart; define `--make` behaviour).
3. Restart the browser after any example that exceeds a duration threshold and log the
   outstanding request URLs at timeout.
4. Re-gate on post-init quiescence (wait for WebGPU init, then require network idle again,
   with a fallback for examples that never request a frame), or start loads before
   `await renderer.init()` in the 19 examples that load after it.
5. Do not "fix" the ICD path. Make the intended software adapter explicit: drop
   `--enable-features=Vulkan`, the `VK_DRIVER_FILES` line and the Mesa install together (or
   keep Mesa and an explicit disable), document SwiftShader, assert the adapter per shard.
6. Audit the exception list under the diagnostics from (1).

Not recommended until 1–4 land: regenerating WebGPU baselines, or any Lavapipe migration.

## 6. Things I got wrong along the way (kept for honesty)

Universal "first-in-shard" claim; recommending the ICD path fix (my own symlink experiment
already showed it broke captures); recommending first-rAF gating; the Mesa/Device-Lost
inference; the inverted `ConditionalNode` argument; calling 429s "absent"; "exactly one
frame"; probe sample sizes doubled by a log replay (800 → 400, 201 → 101); "1/400" as a
cold-start rate (1/20 fresh launches); "n=58 non-first passes, max 3.6 s" built from
passes only; "71 runs / ~355 shard-runs" (68 unique runs / 318 result-emitting jobs); and a
naive `grep 429` that matched timestamps. Reviewers' claims that did *not* hold up under
direct verification: `requestAdapter` p50 of 519 ms (absolute timestamps, not durations —
the paired-duration p50 is 55 ms overall / 804 ms for first launches), and that the three
original device-loss offenders are still excluded (PR 33346 un-excluded them).

## 7. Referenced upstream work

PR 33346 (SwiftShader → "Lavapipe", 2026-04-15), PR 33650 (`--disable-gpu-watchdog`,
`uniformFlow` in MaterialX noise, 2026-05-27), PR 34224/34225 (late-rAF fix, 2026-08-13),
PR 34316 (concurrent-tab harness, closed), PR 34474 (video/input stabilisation incl. the
timeout-guard change, 2026-09-06), PR 34486 (light-probe examples excluded).
