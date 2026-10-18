#!/bin/bash
# Build and install the FreeTube iOS app on one or more connected physical
# devices (iPhone and iPad; the app is universal, iOS 17+).
#
#   scripts/install.sh                 pick devices interactively, release build
#   scripts/install.sh --all --launch  every connected device, then launch
#   scripts/install.sh --help          all options
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/FreeTube/FreeTube.xcodeproj"
SCHEME="FreeTube"
DESTINATION_TIMEOUT_SECONDS="${DESTINATION_TIMEOUT_SECONDS:-20}"

BUILD_TYPE="release"
SKIP_BUILD=0
CLEAN_BUILD=0
LAUNCH=0
ALL_DEVICES=0
APP_PATH=""

# UDIDs asked for on the command line (repeatable --device), and the devices
# actually targeted after discovery and preflight. The app is built once and
# installed to every entry of SELECTED_UDIDS; index 0 is the device the build
# is pointed at.
REQUESTED_UDIDS=()
SELECTED_UDIDS=()
SELECTED_NAMES=()

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options]

Build and install the FreeTube iOS app to connected physical devices.

Options:
  --release       Build and install the release app (default)
  --debug         Build and install the debug app
  --clean         Run xcodebuild clean before building (rebuilds every
                  Swift package, including Python and FFmpeg: slow)
  --skip-build    Install the last built .app without running xcodebuild
  --app PATH      Install a specific .app bundle
  --device UDID   Target a specific physical iOS device. Repeat the flag to
                  install to several in one run
  --all           Target every connected physical iOS device
  --launch        Launch the app after installation
  -h, --help      Show this help message

With no --device/--all, the script lists every paired device and asks which to
use, accepting several: "1,3", "1 3", "a" for all, or Enter for whichever are
currently connected. Devices devicectl cannot reach are listed too, marked
[not reachable] — they can still be picked, and preflight will say why if one
does not work. The app is built once and installed to each target in turn, so
every one has to be covered by the signing profile the build used.

Builds use Xcode's default DerivedData. A custom -derivedDataPath under /tmp
breaks LNPopupController's private-header lookup, so this script never sets one.

Environment:
  DEVELOPER_DIR     Xcode Developer dir to build with (default: the active one
                    from xcode-select).
  DEVELOPMENT_TEAM  Apple team ID to sign with, overriding the one in the
                    project. Needed when Xcode has no account for the project's
                    team ("No Account for Team" at build time).

Examples:
  scripts/install.sh
  scripts/install.sh --launch
  scripts/install.sh --all --launch
  scripts/install.sh --device UDID-A --device UDID-B
  scripts/install.sh --debug --launch
  scripts/install.sh --skip-build --app path/to/FreeTube.app
EOF
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH."
}

select_xcode() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    log "Using DEVELOPER_DIR from environment: ${DEVELOPER_DIR}"
    return
  fi

  log "Using Xcode toolchain: $(xcode-select -p 2>/dev/null || echo unknown)"
}

xcode_configuration() {
  if [[ "${BUILD_TYPE}" == "debug" ]]; then
    echo "Debug"
  else
    echo "Release"
  fi
}

# Enumerate physical iOS devices via devicectl. Every one is kept; whether it
# is reachable right now is recorded alongside rather than used to hide it.
#
# NOT `xcodebuild -showdestinations`: it blocks indefinitely (no timeout flag)
# trying to reach every device that has ever been paired with this Mac, so one
# stale pairing for a phone that is not here hangs the whole script before it
# ever builds. devicectl answers immediately and honours --timeout.
#
# "Reachable" means devicectl reports the device as booted, or gives it a
# transport (wired / localNetwork). A Mac accumulates pairings, so most entries
# are usually neither — but they are still offered, because devicectl's view of
# what is plugged in is not always right, and a device you can see on your desk
# being absent from the list is worse than one that fails preflight with a
# reason.
discover_devices() {
  local devices_json
  devices_json="$(mktemp)"

  log "Discovering iOS devices..."
  if ! xcrun devicectl list devices \
    --timeout "${DESTINATION_TIMEOUT_SECONDS}" \
    --json-output "${devices_json}" >/dev/null 2>&1; then
    rm -f "${devices_json}"
    die "Unable to enumerate connected iOS devices."
  fi

  device_names=()
  device_udids=()
  device_reachable=()

  local line reachable udid name
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    reachable="${line%%$'\t'*}"
    line="${line#*$'\t'}"
    udid="${line%%$'\t'*}"
    name="${line#*$'\t'}"
    device_udids+=("${udid}")
    device_names+=("${name}")
    device_reachable+=("${reachable}")
  done < <(
    python3 - "${devices_json}" <<'DEVICES_JSON'
import json, sys

with open(sys.argv[1]) as handle:
    devices = json.load(handle)["result"]["devices"]

rows = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    # A paired device devicectl has not connected to yet reports no reality
    # at all, so keep everything that is not a simulator.
    if hardware.get("reality") == "simulated":
        continue
    if hardware.get("platform") != "iOS":
        continue
    # The hardware UDID, not devicectl's CoreDevice identifier: xcodebuild's
    # -destination id= only knows the former, and devicectl accepts either.
    identifier = hardware.get("udid") or device.get("identifier")
    name = properties.get("name")
    if not identifier or not name:
        continue
    # Either signal is enough: a wired device that has not been woken yet can
    # report a transport before it reports a bootState.
    reachable = (
        properties.get("bootState") == "booted"
        or connection.get("transportType") is not None
    )
    # Names like "ATM0" and "87654" say nothing about which device they are;
    # the model and OS version are what make the list pickable.
    kind = hardware.get("deviceType") or "iOS"
    version = properties.get("osVersionNumber")
    label = name + " (" + kind + (", iOS " + version if version else "") + ")"
    rows.append((0 if reachable else 1, name.lower(), reachable, identifier, label))

# Reachable first, so the connected devices are the low numbers in the prompt.
for _, _, reachable, identifier, label in sorted(rows):
    print(("1" if reachable else "0") + "\t" + identifier + "\t" + label)
DEVICES_JSON
  )

  rm -f "${devices_json}"

  ((${#device_udids[@]} > 0)) || die "No physical iOS devices are paired with this Mac."
}

# Adds device at discovery index $1 to the target list, ignoring a repeat so
# `--device X --device X` (or "1,1") installs once rather than twice.
select_index() {
  local index="$1" udid="${device_udids[$1]}" existing
  for existing in ${SELECTED_UDIDS[@]+"${SELECTED_UDIDS[@]}"}; do
    [[ "${existing}" == "${udid}" ]] && return 0
  done
  SELECTED_UDIDS+=("${udid}")
  SELECTED_NAMES+=("${device_names[$index]}")
}

index_of_udid() {
  local i
  for i in "${!device_udids[@]}"; do
    if [[ "${device_udids[$i]}" == "$1" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

select_all_devices() {
  local i
  for i in "${!device_udids[@]}"; do
    select_index "$i"
  done
}

# The devices devicectl says are here. What --all and a bare Enter mean: the
# unreachable ones are offered, but never targeted unless asked for by number.
select_reachable_devices() {
  local i
  for i in "${!device_udids[@]}"; do
    [[ "${device_reachable[$i]}" == "1" ]] && select_index "$i"
  done
  ((${#SELECTED_UDIDS[@]} > 0))
}

# Turns one line of interactive input into target selections. Accepts indices
# separated by commas and/or spaces ("1,3", "1 3", "1, 3") and "a"/"all".
# Returns non-zero without selecting anything if the line does not parse, so
# the prompt can be repeated.
parse_selection() {
  local line="$1" token
  local -a picked=()

  # Bare Enter: the devices that are actually here. The common case is one
  # connected phone among several pairings, and typing its number every run
  # would be busywork.
  if [[ -z "${line// /}" ]]; then
    select_reachable_devices && return 0
    echo "No device is currently reachable — pick one by number to try it anyway."
    return 1
  fi

  if [[ "${line}" == "a" || "${line}" == "all" ]]; then
    select_all_devices
    return 0
  fi

  # Commas to spaces, then rely on word splitting for the rest.
  for token in ${line//,/ }; do
    [[ "${token}" =~ ^[0-9]+$ ]] || return 1
    ((token >= 1 && token <= ${#device_udids[@]})) || return 1
    picked+=("$((token - 1))")
  done

  ((${#picked[@]} > 0)) || return 1
  for token in "${picked[@]}"; do
    select_index "${token}"
  done
}

select_devices() {
  discover_devices

  # Explicit --device flags: every one has to resolve, or the run would
  # silently cover fewer devices than asked for.
  if ((${#REQUESTED_UDIDS[@]} > 0)); then
    local requested index
    for requested in "${REQUESTED_UDIDS[@]}"; do
      index="$(index_of_udid "${requested}")" ||
        die "Device '${requested}' is not paired with this Mac."
      select_index "${index}"
    done
  elif ((ALL_DEVICES == 1)); then
    select_reachable_devices ||
      die "No device is currently reachable. Pass --device UDID to try one anyway."
  elif [[ ! -t 0 ]]; then
    # Nobody to ask (piped, CI). Fall back to whatever is connected rather than
    # refusing outright, and only give up if that is ambiguous.
    select_reachable_devices ||
      die "No device is currently reachable. Pass --device UDID (repeatable) or --all."
  else
    # Always ask, even with a single device: the list is also how you find out
    # what this Mac can see, and picking for you hides the one you meant.
    echo "Devices:"
    local i suffix
    for i in "${!device_udids[@]}"; do
      suffix=""
      [[ "${device_reachable[$i]}" == "1" ]] || suffix="   [not reachable]"
      printf '  %d) %s — %s%s\n' \
        "$((i + 1))" "${device_names[$i]}" "${device_udids[$i]}" "${suffix}"
    done

    local selection
    while true; do
      printf 'Select [1-%d, comma separated, "a" for all, Enter for connected]: ' \
        "${#device_udids[@]}"
      read -r selection
      parse_selection "${selection}" && break
      [[ -n "${selection// /}" ]] && echo "Invalid selection."
    done
  fi

  local i
  for i in "${!SELECTED_UDIDS[@]}"; do
    log "Target device: ${SELECTED_NAMES[$i]} — ${SELECTED_UDIDS[$i]}"
  done
}

# Returns non-zero (with the reason on stderr) instead of dying, so one
# unprepared device out of several does not cancel the whole run.
preflight_device() {
  local udid="$1" name="$2" preflight_output
  preflight_output="$(mktemp)"

  log "Preparing developer services on ${name}..."
  if ! xcrun devicectl device info ddiServices \
    --device "${udid}" \
    --timeout "${DESTINATION_TIMEOUT_SECONDS}" >"${preflight_output}" 2>&1; then
    cat "${preflight_output}" >&2
    if grep -q "Developer Mode is disabled" "${preflight_output}"; then
      printf 'Error: Developer Mode is disabled on %s. Enable it in Settings > Privacy & Security > Developer Mode, unlock the device, then rerun this script.\n' \
        "${name}" >&2
    else
      printf 'Error: Unable to prepare developer services on %s.\n' "${name}" >&2
    fi
    rm -f "${preflight_output}"
    return 1
  fi

  rm -f "${preflight_output}"
}

# Drops every target that cannot be prepared. Dying only when none is left
# keeps a run to three iPads useful when one of them is locked.
preflight_devices() {
  local -a ready_udids=() ready_names=()
  local i
  for i in "${!SELECTED_UDIDS[@]}"; do
    if preflight_device "${SELECTED_UDIDS[$i]}" "${SELECTED_NAMES[$i]}"; then
      ready_udids+=("${SELECTED_UDIDS[$i]}")
      ready_names+=("${SELECTED_NAMES[$i]}")
    else
      log "Skipping ${SELECTED_NAMES[$i]}."
    fi
  done

  ((${#ready_udids[@]} > 0)) || die "No target device is ready to install to."

  SELECTED_UDIDS=(${ready_udids[@]+"${ready_udids[@]}"})
  SELECTED_NAMES=(${ready_names[@]+"${ready_names[@]}"})
}

clean_ios_build_artifacts() {
  log "Cleaning iOS build artifacts..."
  if ! xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "$(xcode_configuration)" \
    -destination "id=${SELECTED_UDIDS[0]}" \
    clean >/dev/null; then
    log "Xcode clean did not complete; continuing with the build."
  fi
}

build_ios() {
  if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
    clean_ios_build_artifacts
  fi

  # Built once, for the first target. The output is a device-arch .app that
  # installs to any of them; what has to cover all of them is the signing
  # profile (automatic signing, team set in the project). Pointing the build
  # at a real device lets -allowProvisioningUpdates register it with the team
  # the first time it is used.
  local -a team_setting=()
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    log "Signing with team ${DEVELOPMENT_TEAM} (from environment)."
    team_setting=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
  fi

  log "Building ${BUILD_TYPE} iOS app for ${SELECTED_NAMES[0]}..."
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "$(xcode_configuration)" \
    -destination "id=${SELECTED_UDIDS[0]}" \
    -allowProvisioningUpdates \
    -quiet \
    ${team_setting[@]+"${team_setting[@]}"} \
    build
}

# Where xcodebuild put the .app in the default DerivedData. Asked of
# xcodebuild rather than guessed, since the DerivedData folder name carries a
# per-checkout hash. A generic destination resolves to the same
# <Configuration>-iphoneos folder a device build writes to.
default_app_path() {
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "$(xcode_configuration)" \
    -destination "generic/platform=iOS" \
    -showBuildSettings -json 2>/dev/null |
    python3 -c '
import json, sys
# xcodebuild can print package-resolution text ahead of the JSON.
text = sys.stdin.read()
for entry in json.loads(text[text.find("["):]):
    settings = entry.get("buildSettings", {})
    if settings.get("WRAPPER_EXTENSION") == "app":
        print(settings["TARGET_BUILD_DIR"] + "/" + settings["FULL_PRODUCT_NAME"])
        break
'
}

bundle_identifier() {
  local plist="${APP_PATH}/Info.plist"
  [[ -f "${plist}" ]] || die "Info.plist not found in ${APP_PATH}."

  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}"
}

install_app() {
  local udid="$1" name="$2"

  log "Installing ${APP_PATH} on ${name}..."
  xcrun devicectl device install app --device "${udid}" "${APP_PATH}" || return 1
  log "Installed successfully on ${name}."
}

launch_app() {
  local udid="$1" name="$2" bundle_id
  bundle_id="$(bundle_identifier)"

  log "Launching ${bundle_id} on ${name}..."
  xcrun devicectl device process launch --device "${udid}" "${bundle_id}" || return 1
}

# Installs (and optionally launches) on every target. A device that fails does
# not stop the others — with several devices, giving up on the first failure
# leaves the run half done and says nothing about the rest.
install_all() {
  [[ -d "${APP_PATH}" ]] || die ".app bundle not found: ${APP_PATH}"

  local -a failed=()
  local i
  for i in "${!SELECTED_UDIDS[@]}"; do
    if ! install_app "${SELECTED_UDIDS[$i]}" "${SELECTED_NAMES[$i]}"; then
      failed+=("${SELECTED_NAMES[$i]}")
      continue
    fi
    if [[ "${LAUNCH}" -eq 1 ]]; then
      launch_app "${SELECTED_UDIDS[$i]}" "${SELECTED_NAMES[$i]}" ||
        failed+=("${SELECTED_NAMES[$i]} (launch)")
    fi
  done

  if ((${#failed[@]} > 0)); then
    printf 'Error: failed on %d of %d devices: %s\n' \
      "${#failed[@]}" "${#SELECTED_UDIDS[@]}" "$(printf '%s, ' "${failed[@]}" | sed 's/, $//')" >&2
    exit 1
  fi

  if ((${#SELECTED_UDIDS[@]} > 1)); then
    log "Done: ${#SELECTED_UDIDS[@]} devices."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      BUILD_TYPE="release"
      ;;
    --debug)
      BUILD_TYPE="debug"
      ;;
    --clean)
      CLEAN_BUILD=1
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    --app)
      [[ $# -ge 2 ]] || die "--app requires a path"
      APP_PATH="$2"
      SKIP_BUILD=1
      shift
      ;;
    --device)
      [[ $# -ge 2 ]] || die "--device requires a UDID"
      REQUESTED_UDIDS+=("$2")
      shift
      ;;
    --all)
      ALL_DEVICES=1
      ;;
    --launch)
      LAUNCH=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
  shift
done

require_command xcodebuild
require_command xcrun
# Parses devicectl's and xcodebuild's JSON.
require_command python3

select_xcode

[[ -d "${PROJECT_PATH}" ]] || die "Xcode project not found at ${PROJECT_PATH}."

select_devices
preflight_devices

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  build_ios
fi

if [[ -z "${APP_PATH}" ]]; then
  APP_PATH="$(default_app_path)"
fi

[[ -n "${APP_PATH}" ]] || die "Built app not found. Remove --skip-build to build first."

install_all
