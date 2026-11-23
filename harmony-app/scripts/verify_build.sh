#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify_build.sh — offline verification of the built HAP + protocol self-tests.
#
# This is what we can prove WITHOUT a signed install (retail device needs an
# AGC-issued certificate, see sign/debug-signing.md):
#   * HAP contains the ArkTS bundle, the NAPI libdecoder.so and profile config
#   * libdecoder.so is arm64 and links the expected OH_VideoDecoder / window APIs
#   * module.json has INTERNET/GET_NETWORK_INFO, landscape orientation, metadata
#   * the Python mock host protocol self-tests + localhost loopback pass
#
# Usage: scripts/verify_build.sh [hap]
# Exit code 0 = all checks passed.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

HAP="${1:-$UNSIGNED_HAP}"
PASS=0
FAIL=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

echo "== HaloLink build verification =="
echo "   hap: $HAP"

if [ ! -f "$HAP" ]; then
  bad "HAP not found: $HAP (run scripts/build.sh)"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$HAP" -d "$TMP" || { bad "cannot unzip HAP"; exit 1; }

# --- 1. packaged contents --------------------------------------------------
check '[ -f "$TMP/ets/modules.abc" ] && [ $(stat -f%z "$TMP/ets/modules.abc" 2>/dev/null || stat -c%s "$TMP/ets/modules.abc") -gt 50000 ]' \
  "ArkTS bytecode ets/modules.abc present and non-trivial"
check '[ -f "$TMP/libs/arm64-v8a/libdecoder.so" ]' "NAPI libdecoder.so packaged (arm64-v8a)"
check '[ -f "$TMP/resources/base/profile/network_config.json" ]' "network_config.json packaged (cleartext http for Web fallback)"
check '[ -f "$TMP/module.json" ] && [ -f "$TMP/pack.info" ]' "module.json / pack.info present"

# --- 2. native symbols -----------------------------------------------------
NM="$OHOS_TOOLS/sdk/default/openharmony/native/llvm/bin/llvm-nm"
if [ -x "$NM" ] && [ -f "$TMP/libs/arm64-v8a/libdecoder.so" ]; then
  SYMS="$("$NM" -D "$TMP/libs/arm64-v8a/libdecoder.so" 2>/dev/null || true)"
  for sym in OH_VideoDecoder_CreateByMime OH_VideoDecoder_Configure OH_VideoDecoder_SetSurface \
             OH_VideoDecoder_Prepare OH_VideoDecoder_Start OH_VideoDecoder_PushInputBuffer \
             OH_VideoDecoder_RenderOutputBuffer OH_NativeWindow_CreateNativeWindowFromSurfaceId \
             OH_NativeWindow_NativeWindowHandleOpt; do
    if echo "$SYMS" | grep -q " U $sym$"; then
      ok "libdecoder.so links $sym"
    else
      bad "libdecoder.so missing symbol $sym"
    fi
  done
  if "$NM" -D --defined-only "$TMP/libs/arm64-v8a/libdecoder.so" 2>/dev/null | grep -q "napi_module_register\|RegisterHaloLinkDecoderModule"; then
    ok "libdecoder.so exports the NAPI module registration"
  else
    # registration is via constructor; fall back to checking for napi symbols
    if echo "$SYMS" | grep -q "napi_module_register"; then
      ok "libdecoder.so uses napi_module_register"
    else
      bad "libdecoder.so NAPI registration not found"
    fi
  fi
else
  bad "llvm-nm or libdecoder.so missing"
fi

# --- 3. module.json permissions / orientation -----------------------------
python3 - "$TMP/module.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    mod = json.load(f)
module = mod["module"]
app = mod.get("app", {})
problems = []
perms = [p.get("name") for p in module.get("requestPermissions", [])]
for want in ("ohos.permission.INTERNET", "ohos.permission.GET_NETWORK_INFO"):
    if want not in perms:
        problems.append(f"missing permission {want}")
if not perms:
    problems.append("no requestPermissions")
abilities = module.get("abilities", [])
if not abilities:
    problems.append("no abilities")
else:
    ab = abilities[0]
    if ab.get("orientation") != "landscape":
        problems.append(f"orientation is {ab.get('orientation')!r}, expected 'landscape'")
    if ab.get("name") != "EntryAbility":
        problems.append("ability name mismatch")
meta = [m.get("name") for m in module.get("metadata", [])]
if "ohos.net.network_security_config" not in meta:
    problems.append("missing network_security_config metadata")
if app.get("bundleName") != "com.halolink.display":
    problems.append(f"bundleName is {app.get('bundleName')!r}")
if app.get("versionName") != "0.1.0":
    problems.append(f"versionName is {app.get('versionName')!r}")
if problems:
    print("  [FAIL] module.json: " + "; ".join(problems))
    sys.exit(1)
print(f"  [PASS] module.json: bundle={app.get('bundleName')} v{app.get('versionName')} "
      f"orientation={abilities[0].get('orientation')} perms={perms}")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# --- 3b. host-native Annex-B parser tests ---------------------------------
echo "== native Annex-B parser tests (host compile of shipping code) =="
if "$APP_DIR/test/native/run_tests.sh" >"$TMP/annexb.log" 2>&1; then
  ok "native SPS/PPS Annex-B extraction tests (22 checks)"
else
  bad "native Annex-B tests"
  tail -30 "$TMP/annexb.log"
fi

# --- 4. mock host protocol tests ------------------------------------------
echo "== protocol self-tests (test/mock_host.py) =="
if python3 "$APP_DIR/test/mock_host.py" --self-test >"$TMP/selftest.log" 2>&1; then
  ok "mock host protocol unit tests"
else
  bad "mock host protocol unit tests"
  cat "$TMP/selftest.log"
fi
if python3 "$APP_DIR/test/mock_host.py" --loopback >"$TMP/loopback.log" 2>&1; then
  ok "mock host <-> fake tablet loopback (handshake + framed H.264 stream)"
else
  bad "mock host loopback"
  cat "$TMP/loopback.log"
fi

# --- 5. summary ------------------------------------------------------------
echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
