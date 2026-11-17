#!/usr/bin/env bash
# Publishes a FreeTube release for macOS on this repository's GitHub releases page.
#
#   scripts/publish.sh 1.2.0                     # build, notarize, release, tag
#   scripts/publish.sh 1.2.0 --no-upload         # build and stage only; publish nothing
#   scripts/publish.sh 1.2.0 --reuse-artifacts   # retry a failed upload without rebuilding
#   scripts/publish.sh 1.2.0 --allow-branch      # release from a branch other than main
#
# Modeled on 115Lab's publish.sh, minus what FreeTube doesn't have: no in-app updater (so no
# signed update manifest), no separate release repository, no Windows or Android build. iOS
# goes to TestFlight instead: scripts/publish_testflight.sh.
#
# What it does:
#   1. Preflight: version x.y.z, a clean working tree on main in sync with origin, no existing
#      tag or release v<version>, gh signed in with write access.
#   2. Release notes: release-notes/FreeTube-<version>.md when it exists (used verbatim; may be
#      empty), else generated from the commits since the last v* tag and shown for review —
#      [y]es publishes them, [e]dit opens them in $EDITOR. Without a terminal the file is
#      required: notes go to a public page and are never published unreviewed.
#   3. scripts/build-mac-release.sh builds the notarized DMG (see it for signing requirements),
#      with the commit count as build number — monotonic, and the same for anyone building
#      this commit.
#   4. Creates the GitHub release v<version> on this commit with the DMG and its SHA-256, then
#      fetches the tag GitHub made.
#
# Requires: gh (signed in to an account that can write to this repository), plus whatever
# scripts/build-mac-release.sh needs (Developer ID identity, notarytool profile, Xcode account).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$DIST_DIR/release"
RELEASE_BRANCH=main

VERSION=""
NO_UPLOAD=false
ALLOW_BRANCH=false
REUSE=false

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-upload) NO_UPLOAD=true ;;
    --allow-branch) ALLOW_BRANCH=true ;;
    --reuse-artifacts) REUSE=true ;;
    -h | --help) sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ -z "$VERSION" ]] || die "version given twice: $VERSION and $1"
      VERSION="${1#v}"
      ;;
  esac
  shift
done

# ---------------------------------------------------------------- preflight

step "preflight"

[[ -n "$VERSION" ]] || die "usage: $0 VERSION [--no-upload] [--reuse-artifacts] [--allow-branch]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be x.y.z: $VERSION"
TAG="v$VERSION"

BUILD_NUMBER="$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse HEAD)"
info "version:  $VERSION ($BUILD_NUMBER), commit ${COMMIT:0:12}"

git diff --quiet && git diff --cached --quiet ||
  die "working tree is dirty — commit or stash before releasing"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "$TAG already exists. Releases are immutable; bump the version instead."
fi

if ! $NO_UPLOAD; then
  command -v gh >/dev/null 2>&1 || die "gh not found (brew install gh)"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" ||
    die "gh cannot see this repository's GitHub remote"
  PERMISSION="$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission)"
  case "$PERMISSION" in
    ADMIN | MAINTAIN | WRITE) ;;
    *) die "gh's account has $PERMISSION access to $REPO; releasing needs write access" ;;
  esac
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "$REPO already has a release $TAG (perhaps a draft); delete it or bump the version"
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "origin already has the tag $TAG; bump the version"
  fi

  if ! $ALLOW_BRANCH; then
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    [[ "$BRANCH" == "$RELEASE_BRANCH" ]] ||
      die "on branch '$BRANCH', but releases are cut from '$RELEASE_BRANCH'.
Merge this branch into $RELEASE_BRANCH first, or pass --allow-branch."
  fi
  # The release tags this commit on GitHub, so GitHub must have it.
  git fetch --quiet origin || die "could not reach origin"
  [[ -n "$(git branch -r --contains "$COMMIT")" ]] ||
    die "${COMMIT:0:12} isn't on origin yet — push it first: git push"
  if ! $ALLOW_BRANCH; then
    [[ "$COMMIT" == "$(git rev-parse "origin/$RELEASE_BRANCH")" ]] ||
      die "$RELEASE_BRANCH isn't in sync with origin/$RELEASE_BRANCH — pull or push first"
  fi
  info "release:  $TAG on $REPO"
fi

# ------------------------------------------------------------------- notes

# These notes are published on a public page. Generated ones are a draft to review, never
# unattended release copy.
NOTES_SRC="$ROOT_DIR/release-notes/FreeTube-$VERSION.md"
NOTES_FILE="$STAGE_DIR/notes.md"
mkdir -p "$STAGE_DIR"

if [[ -f "$NOTES_SRC" ]]; then
  cp "$NOTES_SRC" "$NOTES_FILE"
  info "notes:    release-notes/FreeTube-$VERSION.md (hand-written)"
else
  PREV_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [[ -n "$PREV_TAG" ]]; then
    LOG_ARGS=("$PREV_TAG..HEAD")
    info "notes:    generated from $PREV_TAG..HEAD"
  else
    # First release: capped, so the whole history doesn't become a changelog.
    LOG_ARGS=(-n 30 HEAD)
    info "notes:    generated from the last 30 commits (no previous release)"
  fi

  # One line per change. A squash merge keeps each original subject as a "* ..." line in its
  # body, with only the PR title as subject — so those lines win when present.
  collect_subjects() {
    local sha bullets
    for sha in $(git log --no-merges --pretty=tformat:'%H' "${LOG_ARGS[@]}"); do
      bullets="$(git log -1 --pretty=tformat:'%b' "$sha" | sed -nE 's/^\*[[:space:]]+//p')"
      if [[ -n "$bullets" ]]; then
        printf '%s\n' "$bullets"
      else
        git log -1 --pretty=tformat:'%s' "$sha"
      fi
    done
  }
  collect_subjects \
    | grep -viE '^(chore|ci|build|test|style|refactor|docs)(\([^)]*\))?!?:' \
    | grep -viE '^(release|bump|merge|wip)\b' \
    | sed -E 's/ *\(#[0-9]+\)$//' \
    | sed -E 's/^/- /' \
    >"$NOTES_FILE" || true

  if ! $NO_UPLOAD; then
    [[ -t 0 ]] || die "generated release notes need an interactive review before upload.
Write them to release-notes/FreeTube-$VERSION.md (an empty file publishes no notes) and re-run."
    while :; do
      printf '\n--- release notes for %s (%s) ---\n' "$VERSION" "$NOTES_FILE"
      if grep -qE '[^[:space:]]' "$NOTES_FILE"; then cat "$NOTES_FILE"; else printf '(no notes)\n'; fi
      printf -- '---\n\nPublish these notes? [y]es / [e]dit / [N]o: '
      read -r reply
      case "$reply" in
        y | Y) break ;;
        e | E) "${EDITOR:-${VISUAL:-vi}}" "$NOTES_FILE" ;;
        *) die "aborted. To keep this draft, copy it and re-run:
  mkdir -p release-notes && cp \"$NOTES_FILE\" release-notes/FreeTube-$VERSION.md" ;;
      esac
    done
  fi
fi

# ------------------------------------------------------------------- build

DMG="$STAGE_DIR/FreeTube-$VERSION.dmg"
SUMS="$STAGE_DIR/SHA256SUMS"

if $REUSE; then
  step "reusing the staged disk image"
  [[ -f "$DMG" ]] || die "--reuse-artifacts, but there is no $DMG. Run without it."
  # Only a notarized image may go out; a --skip-notarize leftover would be refused by every Mac.
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || die "$DMG has no stapled notarization ticket"
  info "$DMG"
else
  # Staged from scratch, so nothing left over from an earlier attempt is published.
  find "$STAGE_DIR" -maxdepth 1 -type f ! -name notes.md -delete
  step "building macOS (signs and notarizes — this takes a while)"
  BUILD_NUMBER="$BUILD_NUMBER" bash "$ROOT_DIR/scripts/build-mac-release.sh" "$VERSION"
  mv "$DIST_DIR/FreeTube-$VERSION.dmg" "$DMG"
fi

(cd "$STAGE_DIR" && shasum -a 256 "$(basename "$DMG")" >"$SUMS")
info "$(cat "$SUMS")"

if $NO_UPLOAD; then
  step "done (--no-upload)"
  info "staged in $STAGE_DIR"
  exit 0
fi

# ----------------------------------------------------------------- publish

step "creating the GitHub release $TAG"
gh release create "$TAG" \
  --repo "$REPO" \
  --target "$COMMIT" \
  --title "FreeTube $VERSION" \
  --notes-file "$NOTES_FILE" \
  "$DMG" "$SUMS"
# GitHub made the tag on the release's commit; bring it here so the next release's notes start
# from it.
git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" ||
  warn "couldn't fetch the tag $TAG; run: git fetch --tags"

step "done"
info "$(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
