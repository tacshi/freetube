#!/usr/bin/env bash
# Builds, signs, notarizes and packages FreeTube for macOS (the Mac Catalyst build), for
# distribution through GitHub releases — not the Mac App Store.
#
#   scripts/build-mac-release.sh                  # version from the Xcode project
#   scripts/build-mac-release.sh 1.2.0            # another version
#   scripts/build-mac-release.sh 1.2.0 --upload   # and attach it to the draft release v1.2.0
#   scripts/build-mac-release.sh --skip-notarize  # Developer ID signed, not notarized (local)
#
# Produces dist/FreeTube-<version>.dmg: a universal (arm64 + x86_64) app, Developer ID
# signed with the hardened runtime, notarized and stapled, in a disk image that is itself
# signed, notarized and stapled.
#
# Requires:
#   - Xcode signed in to the team's Apple account (Settings → Accounts). The export asks Apple
#     for a Developer ID provisioning profile — see "Why Xcode exports" below.
#   - A "Developer ID Application" identity in the keychain. DEVELOPER_ID_APPLICATION picks one
#     when there are several, e.g. "Developer ID Application: Your Name (TEAMID)".
#   - A notarytool keychain profile: FREETUBE_NOTARY_PROFILE, "FreeTube" by default, made once
#     with
#       xcrun notarytool store-credentials FreeTube \
#         --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#     Any working profile for the same team will do (FREETUBE_NOTARY_PROFILE=<name>).
#   - For --upload: gh, signed in with access to this repository, and a clean working tree
#     whose commit is pushed — the release tags that commit.
#
# Optional:
#   BUILD_NUMBER=<n>   Override the build number (default: the project's CURRENT_PROJECT_VERSION)
#
# Why Xcode exports, instead of re-signing the bundle with codesign by hand (as 115Lab does for
# its Flutter app): a Catalyst app keeps the sign-in cookies (CLAUDE.md §9) in the
# data-protection keychain, which refuses writes (-34018) unless the app has an application
# identifier — and macOS honours one only from an embedded provisioning profile. So the Mac
# entitlements declare a keychain access group, and `xcodebuild -exportArchive` with method
# developer-id fetches a Developer ID profile for it and signs with it. Signed by hand, without
# the profile, the app would not even launch. The export also re-signs nested bundles, drops
# the debug-only get-task-allow entitlement and applies the hardened runtime.
#
# The App Sandbox is on for the Mac build (FreeTube/FreeTube/FreeTube.entitlements) so the app
# gets its own container: Documents, where downloads live, is not the user's ~/Documents.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/FreeTube/FreeTube.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
OUT_DIR="$ROOT_DIR/dist"
NOTARY_PROFILE="${FREETUBE_NOTARY_PROFILE:-FreeTube}"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION=""
NOTARIZE=true
UPLOAD=false
while (($#)); do
  case "$1" in
    --skip-notarize) NOTARIZE=false ;;
    --upload) UPLOAD=true ;;
    -h | --help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ -z "$VERSION" ]] || die "one version, please: $VERSION or $1"
      VERSION="${1#v}"
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

# ---------------------------------------------------------------- preflight

[[ "$(uname -s)" == "Darwin" ]] || die "releases are built on macOS"
for tool in xcodebuild xcrun security ditto; do
  command -v "$tool" >/dev/null 2>&1 || die "needs $tool (install Xcode)"
done

project_setting() {
  sed -nE "s/^[[:space:]]*$1 = \"?([^\";]*)\"?;/\1/p" "$PBXPROJ" | head -n1
}
[[ -n "$VERSION" ]] || VERSION="$(project_setting MARKETING_VERSION)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "not a version: ${VERSION:-none}"
BUILD_NUMBER="${BUILD_NUMBER:-$(project_setting CURRENT_PROJECT_VERSION)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "not a build number: ${BUILD_NUMBER:-none}"

if $UPLOAD && ! $NOTARIZE; then
  die "--upload with --skip-notarize would publish a build Gatekeeper blocks; notarize it"
fi

# The keychain's one Developer ID Application identity, unless DEVELOPER_ID_APPLICATION names it.
IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  FOUND="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u)"
  [[ -n "$FOUND" ]] || die "no Developer ID Application identity in the keychain"
  [[ "$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')" == 1 ]] ||
    die "several Developer ID identities; set DEVELOPER_ID_APPLICATION to one of:
$FOUND"
  DEVELOPER_ID_APPLICATION="$FOUND"
fi
case "$DEVELOPER_ID_APPLICATION" in
  "Developer ID Application:"*) ;;
  *) die "notarization needs a 'Developer ID Application' identity, got: $DEVELOPER_ID_APPLICATION" ;;
esac
printf '%s\n' "$IDENTITIES" | grep -qF "\"$DEVELOPER_ID_APPLICATION\"" ||
  die "not in the keychain: $DEVELOPER_ID_APPLICATION"
TEAM_ID="$(printf '%s' "$DEVELOPER_ID_APPLICATION" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
[[ -n "$TEAM_ID" ]] || die "could not read a team ID from: $DEVELOPER_ID_APPLICATION"

if $NOTARIZE; then
  # Fail before a long build rather than after it.
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    die "the notarytool keychain profile \"$NOTARY_PROFILE\" doesn't work; make it with
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>
or set FREETUBE_NOTARY_PROFILE to a working profile of the same team"
fi

TAG="v$VERSION"
if $UPLOAD; then
  command -v gh >/dev/null 2>&1 || die "--upload needs gh"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"
  [[ -z "$(git status --porcelain)" ]] || die "--upload needs a clean working tree: the build must be the tagged commit"
  COMMIT="$(git rev-parse HEAD)"
  [[ -n "$(git branch -r --contains "$COMMIT" 2>/dev/null)" ]] || die "push $COMMIT first: the release tags it"
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  if IS_DRAFT="$(gh release view "$TAG" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null)"; then
    [[ "$IS_DRAFT" == true ]] || die "release $TAG of $REPO is already published; pick a new version"
  fi
fi

step "release"
echo "    version:  $VERSION ($BUILD_NUMBER)"
echo "    identity: $DEVELOPER_ID_APPLICATION"
$NOTARIZE && echo "    notary:   $NOTARY_PROFILE" || echo "    notary:   skipped"
$UPLOAD && echo "    upload:   draft $TAG of $REPO"

WORK_DIR="$(mktemp -d -t freetube-release)"
trap 'rm -rf "$WORK_DIR"' EXIT
ARCHIVE="$WORK_DIR/FreeTube.xcarchive"
EXPORT_DIR="$WORK_DIR/export"

# ------------------------------------------------------------------- build

step "archiving (universal Mac Catalyst build)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme FreeTube \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK_DIR/DerivedData" \
  -allowProvisioningUpdates \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -quiet

step "exporting with Developer ID"
cat >"$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -quiet
APP_BUNDLE="$EXPORT_DIR/FreeTube.app"
[[ -d "$APP_BUNDLE" ]] || die "the export made no FreeTube.app"

step "verifying"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/FreeTube"
xcrun lipo "$EXECUTABLE" -verify_arch arm64 x86_64 || die "not universal (arm64 + x86_64): $EXECUTABLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGNATURE="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
printf '%s\n' "$SIGNATURE" | grep -qF "Authority=Developer ID Application" || die "not signed with Developer ID"
printf '%s\n' "$SIGNATURE" | grep -q "flags=.*runtime" || die "no hardened runtime (notarization requires it)"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_BUNDLE" 2>/dev/null | tr -d '\0')"
for key in com.apple.security.app-sandbox com.apple.security.network.client \
  com.apple.application-identifier keychain-access-groups; do
  printf '%s' "$ENTITLEMENTS" | grep -qF "$key" || die "signed without $key"
done
[[ -f "$APP_BUNDLE/Contents/embedded.provisionprofile" ]] ||
  die "no embedded provisioning profile: the keychain entitlement would stop the app launching"
# An unexpanded build variable here is an app that dies at launch (115Lab learned this).
if printf '%s' "$ENTITLEMENTS" | grep -qF '$('; then
  die "entitlements contain an unexpanded build variable"
fi
if printf '%s' "$ENTITLEMENTS" | grep -qF "com.apple.security.get-task-allow"; then
  die "signed with get-task-allow (a debug signature); notarization would reject it"
fi
echo "    universal, Developer ID, hardened runtime, sandboxed, keychain profile embedded"

# ---------------------------------------------------------------- notarize

# Submits one artifact and waits for Apple's verdict; prints the log when it is refused.
submit_and_wait() {
  local target="$1" json status id
  json="$(xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  status="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
  id="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "$json" >&2
    [[ -z "$id" ]] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization of $(basename "$target") failed (${status:-unknown})"
  fi
  echo "    accepted ($id)"
}

if $NOTARIZE; then
  # The app gets its own ticket so it still opens offline once dragged out of the disk image;
  # a ticket stapled only to the DMG doesn't travel with the app.
  step "notarizing the app (uploads to Apple; a few minutes)"
  ditto -c -k --keepParent "$APP_BUNDLE" "$WORK_DIR/FreeTube-submit.zip"
  submit_and_wait "$WORK_DIR/FreeTube-submit.zip"
  step "stapling the app"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
fi

# --------------------------------------------------------------------- dmg

step "building the disk image"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/FreeTube-$VERSION.dmg"
rm -f "$DMG"
DMG_STAGE="$WORK_DIR/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP_BUNDLE" "$DMG_STAGE/FreeTube.app"
ln -s /Applications "$DMG_STAGE/Applications"   # drag-to-install target
# macOS 27 deprecated `hdiutil create`; `diskutil image create` replaces it. Keep hdiutil for
# releases built on older macOS.
if diskutil help image create from >/dev/null 2>&1; then
  diskutil image create from --volumeName FreeTube --format UDZO "$DMG_STAGE" "$DMG" >/dev/null
else
  hdiutil create -volname FreeTube -srcfolder "$DMG_STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"

if $NOTARIZE; then
  # Gatekeeper assesses the downloaded disk image itself, so it needs its own ticket.
  step "notarizing the disk image (uploads to Apple; a few minutes)"
  submit_and_wait "$DMG"
  step "stapling the disk image"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  step "Gatekeeper assessment"
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

# ------------------------------------------------------------------ upload

if $UPLOAD; then
  step "uploading to the draft release $TAG"
  if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPO" --draft --target "$COMMIT" \
      --title "FreeTube $VERSION" --generate-notes >/dev/null
  fi
  gh release upload "$TAG" --repo "$REPO" --clobber "$DMG"
  echo "    draft: $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
  echo "    publish it on GitHub once the notes read right"
fi

echo
$NOTARIZE && echo "==> done" || echo "==> done (not notarized: other Macs will refuse to open it)"
echo "    $DMG"
