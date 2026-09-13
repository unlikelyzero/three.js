#!/usr/bin/env bash
# Reproductions for mrdoob/three.js issue 33559 ("CI: Tests are not consistently running with WebGPU").
# Run from anywhere after `npm ci && npm run build`. Exit code 0 means the behaviour WAS reproduced.
#
#   bash test/e2e/repro-33559/demo.sh device-lost         # harness reports PASS after a WebGPU Device Lost
#   bash test/e2e/repro-33559/demo.sh forced-race         # cold WebGPU init outruns the network-idle gate (+ candidate fix)
#   bash test/e2e/repro-33559/demo.sh adapter             # which WebGPU adapter the harness actually gets (Linux: SwiftShader)
#   bash test/e2e/repro-33559/demo.sh icd as-is|fixed|unset   # Linux only: what VK_DRIVER_FILES really does
#   bash test/e2e/repro-33559/demo.sh cold-sampler [N]    # informational: N fresh-profile launches, natural failure rate
set -uo pipefail
cd "$(dirname "$0")/../../.."

DEMO=${1:-}; [ -n "$DEMO" ] || { sed -n '2,10p' "$0"; exit 2; }

HARNESS=(node test/e2e/puppeteer.js)
if [ "$(uname -s)" = Linux ] && command -v xvfb-run >/dev/null 2>&1; then
	# Same as the real e2e job: headful Chrome under xvfb. GitHub sets CI=true, which the
	# harness would parse as a shard index, so CI is unset and VISIBLE=1 keeps headful mode.
	HARNESS=(xvfb-run -a env -u CI VISIBLE=1 node test/e2e/puppeteer.js)
fi

strip() { sed 's/\x1b\[[0-9;]*m//g; s/JSHandle://; s/\[Browser\] //'; }
show() { grep -aE 'repro-33559|Device Lost:|Restarting|Diff|TEST |Render timeout|vkCreateInstance|Vulkan implementation|SharedImage' | grep -v 'E2E_ICD=' | sed -E 's/^\[[0-9:\/.]+:[A-Z]+:[a-z_\/.]+\([0-9]+\)\] //'; }

OUT=""; RC=0
run() { # run "<label>" "<VAR=val VAR2=val>" example...
	local label=$1 envs=$2; shift 2
	echo "--- $label"
	rm -f .puppeteer_profile/SingletonLock .puppeteer_profile/SingletonSocket .puppeteer_profile/SingletonCookie 2>/dev/null
	OUT=$(env $envs "${HARNESS[@]}" "$@" 2>&1); RC=$?
	printf '%s\n' "$OUT" | strip | show
	echo "(exit code $RC)"
}
has() { [ "$(printf '%s\n' "$OUT" | strip | grep -cE "$1")" -gt 0 ]; } # grep -c reads all input; -q would SIGPIPE under pipefail
verdict() { # verdict <condition-exit-code> <what>
	if [ "$1" -eq 0 ]; then echo; echo "RESULT: $DEMO REPRODUCED — $2"; exit 0
	else echo; echo "RESULT: $DEMO NOT REPRODUCED — $2"; exit 1; fi
}

case "$DEMO" in

device-lost)
	# webgpu_zz_devicelost_probe renders red, then calls renderer.onDeviceLost(...). Its committed
	# baseline is a copy of webgl_geometry_cube.jpg, so a real diff would fail. The harness catches
	# the Device Lost, restarts the browser, and moves on without retrying or failing the example.
	run "device-lost probe + a normal example" "" webgpu_zz_devicelost_probe webgl_geometry_cube
	has 'Restarting browser' && has 'TEST PASSED! 2 screenshots' && [ $RC -eq 0 ]
	verdict $? "Device Lost example was skipped and the run reported PASS (exit 0) with it counted"
	;;

forced-race)
	# The harness opens its render gate on *network idle*. webgpu_pmrem_* only start their asset loads
	# after `await renderer.init()`, so if WebGPU init is still pending when the network goes idle, the
	# gate opens, init finishes, the single allowed frame renders immediately, and the assets arrive after.
	# E2E_DELAY_INIT_MS=4000 makes requestAdapter take 4 s (a cold CI runner takes 1-3 s naturally);
	# E2E_ASSET_LATENCY_MS=300 disables the HTTP cache and adds latency (a cold runner has no asset cache).
	ok=0
	run "control: latency only (must pass)" "E2E_ASSET_LATENCY_MS=300" webgpu_pmrem_cubemap
	has 'Diff 0\.[0-9]% in file: webgpu_pmrem_cubemap' && [ $RC -eq 0 ] || ok=1
	run "forced: init delayed 4 s + latency (must render a blank frame)" "E2E_DELAY_INIT_MS=4000 E2E_ASSET_LATENCY_MS=300" webgpu_pmrem_cubemap
	has 'Diff wrong in (9[0-9]|100)\.[0-9]% of pixels in file: webgpu_pmrem_cubemap' && has 'frame rendered at [0-9]+ms \(webgpu init: done\)' || ok=1
	run "forced + candidate fix E2E_WAIT_INIT=1 (must pass again)" "E2E_DELAY_INIT_MS=4000 E2E_ASSET_LATENCY_MS=300 E2E_WAIT_INIT=1" webgpu_pmrem_cubemap
	has 'Diff 0\.[0-9]% in file: webgpu_pmrem_cubemap' && [ $RC -eq 0 ] || ok=1
	verdict $ok "gate opened before WebGPU init finished; frame rendered before assets; re-arming network idle after init fixes it"
	;;

adapter)
	run "adapter identity as the harness launches Chrome" "" webgpu_pmrem_cubemap
	if [ "$(uname -s)" = Linux ]; then
		echo "--- Vulkan ICDs on this machine:"; ls -1 /usr/share/vulkan/icd.d/ 2>/dev/null || echo "(none)"
		dpkg -l mesa-vulkan-drivers 2>/dev/null | tail -1
		has 'adapter=google/swiftshader' && [ ! -e /usr/share/vulkan/icd.d/lvp_icd.x86_64.json ]
		verdict $? "harness points VK_DRIVER_FILES at a file that does not exist and WebGPU runs on Dawn's SwiftShader"
	else
		echo; echo "RESULT: $DEMO N/A on $(uname -s) (informational only; the ICD claims are Linux/CI specific)"; exit 0
	fi
	;;

icd)
	MODE=${2:-}; case "$MODE" in as-is|fixed|unset) ;; *) echo "usage: demo.sh icd as-is|fixed|unset"; exit 2;; esac
	[ "$(uname -s)" = Linux ] || { echo "RESULT: $DEMO N/A on $(uname -s)"; exit 0; }
	[ "$MODE" = fixed ] && [ ! -e /usr/share/vulkan/icd.d/lvp_icd.json ] && { echo "lvp_icd.json not present; install mesa-vulkan-drivers"; exit 2; }
	run "E2E_ICD=$MODE (Chrome/Dawn stderr shown)" "E2E_ICD=$MODE E2E_DUMPIO=1" webgpu_pmrem_cubemap webgpu_pmrem_scene webgl_geometry_cube
	case "$MODE" in
	as-is)
		has 'TEST PASSED! 3 screenshots' && has 'adapter=google/swiftshader' && has 'vkCreateInstance\(\) failed'
		verdict $? "committed config: Chrome's Vulkan fails to initialise (missing ICD file), Dawn uses SwiftShader, suite passes" ;;
	fixed|unset)
		has 'adapter=google/swiftshader' && has 'Diff wrong in (9[0-9]|100)\.[0-9]% of pixels in file: webgpu_pmrem_cubemap' && has 'Diff wrong in (9[0-9]|100)\.[0-9]% of pixels in file: webgpu_pmrem_scene'
		verdict $? "with a resolvable ICD the compositor moves to Vulkan/llvmpipe, Dawn STILL uses SwiftShader, and WebGPU captures come out blank" ;;
	esac
	;;

cold-sampler)
	N=${2:-10}; fails=0
	for i in $(seq 1 "$N"); do
		rm -rf .puppeteer_profile
		# A shard's first example runs on a cold OS page cache too; drop it where we can (Linux, passwordless sudo).
		sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
		run "fresh profile + dropped page cache, launch $i/$N" "" webgpu_pmrem_cubemap
		has 'Diff wrong' && fails=$((fails+1))
	done
	echo; echo "RESULT: $DEMO informational — $fails/$N fresh-profile launches rendered a blank frame (natural cold-start rate on this machine)"
	exit 0
	;;

*) echo "unknown demo: $DEMO"; exit 2;;
esac
