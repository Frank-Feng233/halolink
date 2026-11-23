#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sign_with_agc.sh — sign the built HAP with *Huawei AGC* developer materials
# (the only signature a retail HarmonyOS device accepts).
#
# You need the three files that DevEco Studio generates when you use
# "Project Structure -> Signing Configs -> Automatically generate signature"
# (login with a Huawei developer account), or that you download from AGC:
#   *.p12  (keystore with your app signing key)
#   *.cer  (certificate chain, PEM)
#   *.p7b  (debug/release provision profile bound to your bundleName + UDID)
#
# Usage:
#   scripts/sign_with_agc.sh <p12> <cer> <p7b> <storePass> <keyAlias> [keyPass] [hap]
#
#   scripts/sign_with_agc.sh ~/.ohos/config/app.p12 ~/.ohos/config/app.cer \
#       ~/.ohos/config/app.p7b 'MyStorePass' 'MyKeyAlias' 'MyKeyPass'
#
# Optional env:
#   WRITE_BUILD_PROFILE=1  also writes build-profile.json5 signingConfigs +
#                          product.signingConfig so plain `hvigorw assembleHap`
#                          produces a signed HAP afterwards (hvigor may need
#                          DevEco-encrypted passwords; the direct signing path
#                          below always works).
#   BUNDLE_NAME / JAVA_HOME / OHOS_TOOLS as in scripts/env.sh
#
# Output: entry/build/default/outputs/default/entry-default-agc-signed.hap
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

P12="${1:-${AGC_P12:-}}"
CER="${2:-${AGC_CER:-}}"
P7B="${3:-${AGC_P7B:-}}"
STOREPASS="${4:-${AGC_PASS:-}}"
KEYALIAS="${5:-${AGC_ALIAS:-}}"
KEYPASS="${6:-${AGC_KEYPASS:-$STOREPASS}}"
HAP="${7:-$UNSIGNED_HAP}"
OUT_HAP="${8:-$AGC_SIGNED_HAP}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$P12" ] && [ -f "$P12" ] || die "p12 not found: '$P12' (arg 1)"
[ -n "$CER" ] && [ -f "$CER" ] || die "cer not found: '$CER' (arg 2)"
[ -n "$P7B" ] && [ -f "$P7B" ] || die "p7b not found: '$P7B' (arg 3)"
[ -n "$STOREPASS" ] || die "store password required (arg 4)"
[ -n "$KEYALIAS" ] || die "key alias required (arg 5)"
[ -f "$HAP" ] || die "hap not found: $HAP (run scripts/build.sh first)"

SIGN_LIB="$OHOS_TOOLS/sdk/default/openharmony/toolchains/lib"
SIGN_TOOL="$SIGN_LIB/hap-sign-tool.jar"
[ -f "$SIGN_TOOL" ] || die "hap-sign-tool.jar not found under $SIGN_LIB"
[ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] || die "JAVA_HOME not set (need JDK 8/11/17)"
JAVA_VER="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | awk -F'"' '{print $2}')"
echo "== HaloLink AGC signing =="
echo "   java       : $JAVA_VER ($JAVA_HOME)"
echo "   hap        : $HAP"
echo "   cert       : $CER"
echo "   profile    : $P7B"
echo "   keystore   : $P12"
echo "   key alias  : $KEYALIAS"
echo "   output     : $OUT_HAP"

# --- 1. sanity check the profile (must be a signed p7b for this device) -----
"$JAVA_HOME/bin/java" -jar "$SIGN_TOOL" verify-profile \
  -inFile "$P7B" -outFile "$(dirname "$P7B")/halolink-verify-profile.json" \
  || die "profile verification failed (is the .p7b a valid signed provision profile?)"

# --- 2. sign the HAP -------------------------------------------------------
"$JAVA_HOME/bin/java" -jar "$SIGN_TOOL" sign-app \
  -mode "localSign" \
  -keyAlias "$KEYALIAS" \
  -keyPwd "$KEYPASS" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -inFile "$HAP" \
  -signAlg "SHA256withECDSA" \
  -keystoreFile "$P12" \
  -keystorePwd "$STOREPASS" \
  -outFile "$OUT_HAP" \
  -compatibleVersion 21 \
  -signCode 1 || die "sign-app failed"

# --- 3. verify the result --------------------------------------------------
"$JAVA_HOME/bin/java" -jar "$SIGN_TOOL" verify-app \
  -inFile "$OUT_HAP" \
  -outCertChain "$OUT_HAP.chain.cer" \
  -outProfile "$OUT_HAP.p7b" \
  || die "verify-app failed"

# --- 4. optional: persist the config so hvigor signs on every build ---------
if [ "${WRITE_BUILD_PROFILE:-0}" = "1" ]; then
  python3 - "$APP_DIR/build-profile.json5" "$P12" "$CER" "$P7B" "$STOREPASS" \
    "$KEYALIAS" "$KEYPASS" <<'PY'
import json, sys
path, p12, cer, p7b, storepass, alias, keypass = sys.argv[1:8]
with open(path) as f:
    profile = json.load(f)
signing = {
    "name": "default",
    "type": "HarmonyOS",
    "material": {
        "storeFile": p12,
        "storePassword": storepass,
        "keyAlias": alias,
        "keyPassword": keypass,
        "certpath": cer,
        "profile": p7b,
        "signAlg": "SHA256withECDSA",
    },
}
profile["app"]["signingConfigs"] = [signing]
for product in profile["app"].get("products", []):
    product["signingConfig"] = "default"
with open(path, "w") as f:
    json.dump(profile, f, indent=2)
    f.write("\n")
print(f"WROTE {path} signingConfigs=default")
PY
  echo "   build-profile.json5 updated (backup it / revert with git if needed)"
  echo "   NOTE: hvigor may require DevEco-encrypted passwords; if assembleHap"
  echo "         fails to sign, keep using this script's direct-signing path."
fi

echo
echo "SIGNED OK  ->  $OUT_HAP"
echo "next:"
echo "  DEVICE=<tablet-ip>:<port> scripts/install.sh \"$OUT_HAP\""
echo "  or: scripts/deploy.sh    (build + sign + install + launch + fport)"
