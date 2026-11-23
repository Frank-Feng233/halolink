#!/bin/bash
#
# make_app.sh — build halolink-host and package it as HaloLink.app
#
# Why an .app bundle? macOS attributes Screen Recording / Accessibility TCC
# permissions to a *code identity*. A bare command line binary has no stable
# bundle identity (and on macOS 26.1+ non-bundled executables no longer even show
# up in the Screen Recording list), so TCC would not survive rebuilds.
#
# Signing strategy (best effort, never blocks the build):
#   1. $HALOLINK_SIGN_IDENTITY if set and usable;
#   2. an existing "HaloLink Self-Signed" code signing identity in the login
#      keychain (stable identity => TCC permission survives rebuilds);
#   3. ad-hoc "codesign -s -" (works, but TCC is reset on every rebuild because
#      the cdhash changes — the script prints a warning in that case).
#
# Usage:
#   bash scripts/make_app.sh              # build + bundle into macos-host/HaloLink.app
#   CONFIG=debug bash scripts/make_app.sh # debug build
#   NO_SIGN=1 bash scripts/make_app.sh    # skip codesign entirely
#
set -u -o pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="HaloLink"
APP="${ROOT}/${APP_NAME}.app"
BINARY_NAME="halolink-host"
BUNDLE_ID="com.halolink.host"
VERSION="1.3.1"

log() { printf '[make_app] %s\n' "$*"; }
die() { printf '[make_app] ERROR: %s\n' "$*" >&2; exit 1; }

# Run a command with a hard timeout (macOS has no /usr/bin/timeout by default).
run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$seconds"; kill -9 "$cmd_pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$cmd_pid"
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# ---------------------------------------------------------------- build ----
log "building (swift build -c ${CONFIG}) …"
if ! swift build -c "${CONFIG}"; then
  die "swift build failed"
fi
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BINARY="${BIN_DIR}/${BINARY_NAME}"
[ -x "${BINARY}" ] || die "binary not found at ${BINARY}"
log "binary: ${BINARY}"

# ---------------------------------------------------------------- bundle ---
log "creating ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BINARY}" "${APP}/Contents/MacOS/${BINARY_NAME}"
chmod +x "${APP}/Contents/MacOS/${BINARY_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>HaloLink</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${BINARY_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>110</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Double-clickable app: show in the Dock and Cmd-Tab, plus a menu bar item. -->
    <key>LSUIElement</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Shown in the Screen Recording permission prompt / System Settings. -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>HaloLink captures the extended virtual display so it can stream it to your tablet.</string>
    <!-- Shown when the tablet browser connects over the local network. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>HaloLink serves the browser fallback (MJPEG + touch) and connects to the tablet app over your local network.</string>
    <key>NSHumanReadableCopyright</key><string>HaloLink</string>
</dict>
</plist>
PLIST

plutil -lint "${APP}/Contents/Info.plist" >/dev/null 2>&1 || die "Info.plist is invalid"

# ------------------------------------------------------- bundled hdc ------
# HarmonyOS Device Connector is copied into Contents/Resources/bin/hdc so the
# double-clickable app can auto-connect USB tablets without a separate CLI install.
BIN_DIR="${APP}/Contents/Resources/bin"
mkdir -p "${BIN_DIR}"
HDC_PATH=""
hdc_candidates=(
  "${HALOLINK_HDC:-}"
  "/Library/Developer/CommandLineTools/sdk/default/openharmony/toolchains/hdc"
  "/Library/Developer/CommandLineTools/sdk/default/hms/toolchains/hdc"
  "${HOME}/Library/Huawei/Sdk/default/openharmony/toolchains/hdc"
  "${HOME}/Library/OpenHarmony/Sdk/default/openharmony/toolchains/hdc"
  "${HOME}/command-line-tools/sdk/default/openharmony/toolchains/hdc"
  "${HOME}/harmony/huawei/hdc"
  "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
  "/Applications/DevEco-Studio.app/Contents/tools/hdc"
  "/opt/homebrew/bin/hdc"
  "/usr/local/bin/hdc"
)
for candidate in "${hdc_candidates[@]}"; do
  if [ -n "${candidate}" ] && [ -x "${candidate}" ] && [ ! -d "${candidate}" ]; then
    HDC_PATH="${candidate}"
    break
  fi
done
if [ -z "${HDC_PATH}" ]; then
  # PATH lookup last
  HDC_PATH="$(command -v hdc 2>/dev/null || true)"
fi
if [ -n "${HDC_PATH}" ] && [ -x "${HDC_PATH}" ]; then
  log "bundling hdc: ${HDC_PATH}"
  cp "${HDC_PATH}" "${BIN_DIR}/hdc"
  chmod +x "${BIN_DIR}/hdc"
  # Copy only the dylibs hdc actually references via @rpath (e.g. libusb_shared).
  HDC_DIR="$(dirname "${HDC_PATH}")"
  rpath_deps=$(otool -L "${BIN_DIR}/hdc" 2>/dev/null | awk '/@rpath\//{print $1}' | sed 's|@rpath/||')
  for dep in ${rpath_deps}; do
    if [ -f "${HDC_DIR}/${dep}" ]; then
      cp "${HDC_DIR}/${dep}" "${BIN_DIR}/" && log "  + ${dep}"
    else
      log "  WARNING: hdc dependency not found: ${dep}"
    fi
  done
  # Make the bundled hdc find its dylibs next to itself (before signing).
  if otool -L "${BIN_DIR}/hdc" 2>/dev/null | grep -q "@rpath/"; then
    if ! otool -l "${BIN_DIR}/hdc" 2>/dev/null | grep -A2 LC_RPATH | grep -q "@executable_path"; then
      install_name_tool -add_rpath "@executable_path" "${BIN_DIR}/hdc" 2>/dev/null \
        && log "  + rpath @executable_path added to bundled hdc"
    fi
  fi
  xattr -cr "${BIN_DIR}" 2>/dev/null || true
  # Sign the nested executable(s) with the same identity as the bundle.
  :
else
  log "hdc not found — USB auto-connect will be unavailable (network/Wi-Fi still works)."
  log "  Set HALOLINK_HDC=/path/to/hdc or install HarmonyOS Command Line Tools."
fi

# ---------------------------------------------------------------- signing --
SIGN_ID=""
SIGN_KIND=""

if [ "${NO_SIGN:-0}" = "1" ]; then
  log "NO_SIGN=1: skipping codesign (TCC will treat each build as a new app)"
else
  if [ -n "${HALOLINK_SIGN_IDENTITY:-}" ]; then
    SIGN_ID="${HALOLINK_SIGN_IDENTITY}"
    SIGN_KIND="env"
  elif security find-identity -p codesigning 2>/dev/null | grep -q "HaloLink Self-Signed"; then
    SIGN_ID="HaloLink Self-Signed"
    SIGN_KIND="keychain"
  else
    # Best effort: create a stable self-signed code-signing identity. Some
    # environments cannot create/trust certificates non-interactively; then we
    # simply fall back to ad-hoc signing.
    log "no stable signing identity found; trying to create one (best effort) …"
    TMP_DIR="$(mktemp -d /tmp/halolink-sign.XXXXXX)" || TMP_DIR=""
    if [ -n "${TMP_DIR}" ]; then
      openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${TMP_DIR}/key.pem" -out "${TMP_DIR}/cert.pem" \
        -days 3650 -subj "/CN=HaloLink Self-Signed" \
        -addext "keyUsage=digitalSignature,keyCertSign" \
        -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
      openssl pkcs12 -export -inkey "${TMP_DIR}/key.pem" -in "${TMP_DIR}/cert.pem" \
        -out "${TMP_DIR}/identity.p12" -passout pass:halolink >/dev/null 2>&1
      KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
      if [ -f "${KEYCHAIN}" ]; then
        run_with_timeout 20 security import "${TMP_DIR}/identity.p12" \
          -k "${KEYCHAIN}" -P halolink -T /usr/bin/codesign -T /usr/bin/security \
          >/dev/null 2>&1 || true
        run_with_timeout 10 security set-key-partition-list \
          -S apple-tool:,apple:,codesign: -s -k "" "${KEYCHAIN}" >/dev/null 2>&1 || true
        # Trusting the certificate may require admin/GUI approval: try, ignore failure.
        run_with_timeout 10 security add-trusted-cert -r trustRoot -k "${KEYCHAIN}" \
          "${TMP_DIR}/cert.pem" >/dev/null 2>&1 || true
        if security find-identity -p codesigning 2>/dev/null | grep -q "HaloLink Self-Signed"; then
          SIGN_ID="HaloLink Self-Signed"
          SIGN_KIND="created"
        fi
      fi
      rm -rf "${TMP_DIR}"
    fi
  fi

  if [ -n "${SIGN_ID}" ]; then
    log "codesigning with identity: ${SIGN_ID} (${SIGN_KIND})"
    # Nested executables must be signed before the enclosing bundle.
    shopt -s nullglob
    rm -f "${BIN_DIR}"/*.cstemp 2>/dev/null || true
    for nested in "${BIN_DIR}/hdc" "${BIN_DIR}"/*.dylib; do
      [ -f "${nested}" ] || continue
      [ -x "${nested}" ] || continue
      run_with_timeout 20 codesign --force --sign "${SIGN_ID}" "${nested}" \
        >/dev/null 2>&1 || log "WARNING: could not sign $(basename "${nested}")"
      rm -f "${nested}.cstemp" 2>/dev/null || true
    done
    shopt -u nullglob
    if ! run_with_timeout 30 codesign --force --sign "${SIGN_ID}" \
        --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"; then
      log "WARNING: signing with '${SIGN_ID}' failed; falling back to ad-hoc"
      SIGN_ID=""
    fi
  fi

  if [ -z "${SIGN_ID}" ]; then
    SIGN_KIND="adhoc"
    log "codesigning ad-hoc (codesign -s -)"
    shopt -s nullglob
    rm -f "${BIN_DIR}"/*.cstemp 2>/dev/null || true
    for nested in "${BIN_DIR}/hdc" "${BIN_DIR}"/*.dylib; do
      [ -f "${nested}" ] || continue
      [ -x "${nested}" ] || continue
      run_with_timeout 20 codesign --force --sign - "${nested}" >/dev/null 2>&1 || true
      rm -f "${nested}.cstemp" 2>/dev/null || true
    done
    shopt -u nullglob
    run_with_timeout 30 codesign --force --sign - --identifier "${BUNDLE_ID}" \
      "${APP}" || die "ad-hoc codesign failed"
  fi
fi

# ---------------------------------------------------------------- verify ---
if [ "${NO_SIGN:-0}" != "1" ]; then
  run_with_timeout 15 codesign --verify --deep --strict "${APP}" >/dev/null 2>&1 \
    || log "WARNING: codesign --verify did not pass (app may still run)"
  log "signature:"
  codesign -dv "${APP}" 2>&1 | sed 's/^/[make_app]   /' | head -6 || true
fi

log "app bundle ready: ${APP}"
log ""
log "双击使用：Finder 中双击 HaloLink.app（首次请右键→打开以通过 Gatekeeper）"
log "  open \"${APP}\""
log "  \"${APP}/Contents/MacOS/${BINARY_NAME}\" --help       # CLI 用法"
log "  \"${APP}/Contents/MacOS/${BINARY_NAME}\" --seconds 8 --save-frames /tmp/hl-frames  # 测试"
log ""
case "${SIGN_KIND}" in
  env|keychain|created)
    log "TCC: identity '${SIGN_ID}' is stable across rebuilds — grant Screen Recording /"
    log "     Accessibility to HaloLink once in System Settings."
    ;;
  adhoc)
    log "TCC NOTE: ad-hoc signing changes its cdhash on every rebuild, so macOS resets"
    log "     Screen Recording / Accessibility after each rebuild. For a stable grant,"
    log "     create a self-signed 'Code Signing' certificate in Keychain Access and run:"
    log "       HALOLINK_SIGN_IDENTITY=\"HaloLink Self-Signed\" bash scripts/make_app.sh"
    ;;
  *)
    log "NOTE: app was not signed (NO_SIGN=1); macOS may refuse TCC permissions entirely."
    ;;
esac
