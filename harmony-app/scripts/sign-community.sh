#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sign-community.sh — sign a HAP locally with the OpenHarmony *community*
# signing materials that ship inside the command-line-tools SDK.
#
# WARNING: the community cert chain is NOT trusted by retail HarmonyOS/EMUI
# devices. This script exists to prove/disprove whether the device accepts it.
# For a real device use a Huawei-issued developer certificate (see
# sign/debug-signing.md).
#
# Usage: scripts/sign-community.sh [unsigned.hap] [out-signed.hap]
#   env: OHOS_TOOLS (default $HOME/ohos-tools/command-line-tools)
#        JAVA_HOME  (JDK 8/11/17; JDK 21+ is too new for hap-sign-tool)
#        DEVICE_UDID (optional; if unset read from connected hdc device)
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=env.sh
source "$HERE/scripts/env.sh"
LIB="$OHOS_TOOLS/sdk/default/openharmony/toolchains/lib"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"

UNSIGNED="${1:-$HERE/entry/build/default/outputs/default/entry-default-unsigned.hap}"
OUT="${2:-${UNSIGNED%-unsigned.hap}-community-signed.hap}"
WORK="$HERE/sign/out"
mkdir -p "$WORK"

BUNDLE="${BUNDLE:-com.halolink.display}"
ALIAS_APP="openharmony application release"
ALIAS_PROFILE="openharmony application profile debug"
STORE_PWD="123456"

UDID="${DEVICE_UDID:-}"
if [ -z "$UDID" ]; then
  UDID="$("$HDC" shell bm get -u 2>/dev/null | grep -oE '[0-9A-F]{64}' | head -1 || true)"
fi
if [ -z "$UDID" ]; then
  echo "WARN: no device UDID found, using template device ids" >&2
  UDID="69C7505BE341BDA5948C3C0CB44ABCD530296054159EFE0BD16A16CD0129CC42"
fi
echo "UDID=$UDID"

# 1. Build a debug provision profile for this bundle + device -----------------
NOW=$(date +%s)
python3 - "$LIB/UnsgnedDebugProfileTemplate.json" "$WORK/profile.json" "$BUNDLE" "$UDID" "$NOW" <<'PY'
import json, sys
tpl, out, bundle, udid, now = sys.argv[1:6]
now = int(now)
with open(tpl) as f:
    profile = json.load(f)
profile["bundle-info"]["bundle-name"] = bundle
profile["bundle-info"]["developer-id"] = "HaloLinkLocal"
profile["debug-info"]["device-ids"] = [udid]
profile["validity"]["not-before"] = now - 3600
profile["validity"]["not-after"] = now + 3600 * 24 * 365 * 10
profile["uuid"] = "9d3c8c19-5f3c-4a35-9c0e-7a0d4e1b6f21"
with open(out, "w") as f:
    json.dump(profile, f, indent=2)
PY

# 2. Sign the profile with the OpenHarmony profile-signing key ----------------
"$JAVA" -jar "$LIB/hap-sign-tool.jar" sign-profile \
  -keyAlias "$ALIAS_PROFILE" \
  -signAlg "SHA256withECDSA" \
  -mode "localSign" \
  -profileCertFile "$LIB/OpenHarmonyProfileDebug.pem" \
  -inFile "$WORK/profile.json" \
  -keystoreFile "$LIB/OpenHarmony.p12" \
  -outFile "$WORK/halolink.p7b" \
  -keyPwd "$STORE_PWD" \
  -keystorePwd "$STORE_PWD"

# 3. Export the app-cert chain (leaf + intermediate CA + root CA) to one PEM.
#    The leaf cert issued by the OpenHarmony CA is embedded in the profile
#    template as `development-certificate`; its public key matches the
#    "openharmony application release" private key in the p12 (verified).
python3 - "$LIB/UnsgnedDebugProfileTemplate.json" "$WORK/leaf.pem" <<'PY'
import json, sys
tpl, out = sys.argv[1:3]
with open(tpl) as f:
    profile = json.load(f)
with open(out, "w") as f:
    f.write(profile["bundle-info"]["development-certificate"])
PY
for pair in "ca:openharmony application ca:$WORK/ca.pem" \
            "root:openharmony application root ca:$WORK/root.pem"; do
  alias="${pair#*:}"; alias="${alias%%:*}"
  dest="${pair##*:}"
  keytool -exportcert -rfc -alias "$alias" \
    -keystore "$LIB/OpenHarmony.p12" -storepass "$STORE_PWD" 2>/dev/null | \
    python3 -c "import sys;d=sys.stdin.read();i=d.find('-----BEGIN CERTIFICATE-----');sys.stdout.write(d[i:])" > "$dest"
done
cat "$WORK/leaf.pem" "$WORK/ca.pem" "$WORK/root.pem" > "$WORK/app-chain.pem"

# 4. Sign the HAP ------------------------------------------------------------
"$JAVA" -jar "$LIB/hap-sign-tool.jar" sign-app \
  -mode "localSign" \
  -keyAlias "$ALIAS_APP" \
  -keyPwd "$STORE_PWD" \
  -appCertFile "$WORK/app-chain.pem" \
  -profileFile "$WORK/halolink.p7b" \
  -inFile "$UNSIGNED" \
  -signAlg "SHA256withECDSA" \
  -keystoreFile "$LIB/OpenHarmony.p12" \
  -keystorePwd "$STORE_PWD" \
  -outFile "$OUT" \
  -compatibleVersion 21 \
  -signCode 1

echo "signed HAP: $OUT"
