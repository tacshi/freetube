#!/usr/bin/env bash
# Builds FreeTube for iOS and publishes it to an internal TestFlight group.
#
#   scripts/publish_testflight.sh 1.2.0 23
#
# The build number must be higher than any build already uploaded for that version. Modeled on
# 115Lab's publish_testflight.sh; the Mac build goes to GitHub instead (scripts/publish.sh).
#
# What it does: archives the iOS app (Release), exports it for App Store Connect with automatic
# signing, checks the IPA's version, build number and export-compliance flag, then uploads it
# with `asc publish testflight`, waits for processing and adds it to the tester group.
#
# Requires:
#   - asc (App Store Connect CLI), authenticated: `asc auth doctor` must pass.
#   - FreeTube's app record in App Store Connect for bundle ID app.capyvibe.freetube (found by
#     bundle ID; ASC_APP_ID overrides). The API can't create one: make it once on
#     appstoreconnect.apple.com → Apps → + → New App.
#   - A TestFlight group: ASC_TESTFLIGHT_GROUP, "FreeTube Testers" by default — an internal
#     group, so builds reach testers without Beta App Review.
#   - Xcode signed in to the team's Apple account, for the App Store distribution signing.
#
# Optional: ASC_TESTFLIGHT_TIMEOUT (default 45m) for upload + processing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/FreeTube/FreeTube.xcodeproj"
BUNDLE_ID="app.capyvibe.freetube"
TESTFLIGHT_GROUP="${ASC_TESTFLIGHT_GROUP:-FreeTube Testers}"
TIMEOUT="${ASC_TESTFLIGHT_TIMEOUT:-45m}"
OUT_DIR="$ROOT_DIR/dist/testflight"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

[[ $# -eq 2 ]] || die "usage: $0 <version> <build>"
VERSION="${1#v}"
BUILD_NUMBER="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must use x.y.z format: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "build must be a positive integer: $BUILD_NUMBER"

for tool in asc xcodebuild unzip plutil; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

cd "$ROOT_DIR"

git diff --quiet && git diff --cached --quiet ||
  die "working tree is dirty — commit or stash before publishing"

# ---------------------------------------------------------------- preflight

step "checking App Store Connect"
asc auth doctor >/dev/null || { asc auth doctor; die "asc authentication has problems (above)"; }

APP_ID="${ASC_APP_ID:-}"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(asc apps list --bundle-id "$BUNDLE_ID" --output json |
    /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); d=d.get("data",d) if isinstance(d,dict) else d; print(d[0]["id"] if d else "")')"
fi
[[ -n "$APP_ID" ]] || die "no App Store Connect app for $BUNDLE_ID.
Create it once at appstoreconnect.apple.com → Apps → + → New App (platform iOS, bundle ID
$BUNDLE_ID), then re-run. Or set ASC_APP_ID if it exists under another account."
info "app:      $APP_ID ($BUNDLE_ID)"

GROUPS_JSON="$(asc testflight groups list --app "$APP_ID" --output json)"
printf '%s' "$GROUPS_JSON" | TESTFLIGHT_GROUP="$TESTFLIGHT_GROUP" /usr/bin/python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d = d.get("data", d) if isinstance(d, dict) else d
names = [g.get("attributes", {}).get("name", g.get("name")) for g in d]
sys.exit(0 if os.environ["TESTFLIGHT_GROUP"] in names else 1)' ||
  die "no TestFlight group \"$TESTFLIGHT_GROUP\" for app $APP_ID.
Create an internal group with that name in App Store Connect → TestFlight, or set
ASC_TESTFLIGHT_GROUP to an existing one."
info "group:    $TESTFLIGHT_GROUP"

# ------------------------------------------------------------------- build

WORK_DIR="$(mktemp -d -t freetube-testflight)"
trap 'rm -rf "$WORK_DIR"' EXIT
ARCHIVE="$WORK_DIR/FreeTube.xcarchive"

step "archiving FreeTube $VERSION ($BUILD_NUMBER) for iOS"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme FreeTube \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK_DIR/DerivedData" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

step "exporting for App Store Connect"
cat >"$WORK_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
rm -rf "$OUT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT_DIR" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -quiet

shopt -s nullglob
IPAS=("$OUT_DIR"/*.ipa)
[[ ${#IPAS[@]} -eq 1 ]] || die "expected one IPA in $OUT_DIR, found ${#IPAS[@]}"
IPA="${IPAS[0]}"

# ------------------------------------------------------------------ verify

# BSD awk needs the slash escaped even inside a character class.
INFO_PLIST="$(unzip -Z1 "$IPA" | awk '/^Payload\/[^\/]+\.app\/Info\.plist$/ { print; exit }')"
[[ -n "$INFO_PLIST" ]] || die "could not find the app's Info.plist in $IPA"
plist_value() { unzip -p "$IPA" "$INFO_PLIST" | plutil -extract "$1" raw -o - -; }

PACKAGED_ID="$(plist_value CFBundleIdentifier)"
PACKAGED_VERSION="$(plist_value CFBundleShortVersionString)"
PACKAGED_BUILD="$(plist_value CFBundleVersion)"
USES_NON_EXEMPT_ENCRYPTION="$(plist_value ITSAppUsesNonExemptEncryption)"

[[ "$PACKAGED_ID" == "$BUNDLE_ID" ]] || die "IPA bundle ID is $PACKAGED_ID, expected $BUNDLE_ID"
[[ "$PACKAGED_VERSION" == "$VERSION" ]] || die "IPA version is $PACKAGED_VERSION, expected $VERSION"
[[ "$PACKAGED_BUILD" == "$BUILD_NUMBER" ]] || die "IPA build is $PACKAGED_BUILD, expected $BUILD_NUMBER"
# Without it, every build waits on the export-compliance question in App Store Connect.
[[ "$USES_NON_EXEMPT_ENCRYPTION" == "false" ]] || die "IPA must declare ITSAppUsesNonExemptEncryption=false"
info "$IPA"

# ----------------------------------------------------------------- publish

step "publishing $VERSION ($BUILD_NUMBER) to \"$TESTFLIGHT_GROUP\""
asc publish testflight \
  --app "$APP_ID" \
  --ipa "$IPA" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --group "$TESTFLIGHT_GROUP" \
  --wait \
  --timeout "$TIMEOUT" \
  --output table

step "published $VERSION ($BUILD_NUMBER) to internal TestFlight"
