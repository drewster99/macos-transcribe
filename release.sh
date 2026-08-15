#!/bin/bash
#
# Build, sign, notarize, and publish a transcribe release.
#
# Produces three assets on a GitHub release:
#   transcribe-<version>.pkg              signed, notarized, stapled; installs /usr/local/bin/transcribe
#   transcribe-<version>-macos-arm64.tar.gz   the bare signed binary
#   SHA256SUMS                            checksums for both
#
# and updates the Homebrew formula in the tap.
#
# A bare Mach-O executable cannot be stapled — only bundles, disk images, and packages can carry a
# stapled ticket. That is why the .pkg exists: it is the install path that works offline. The
# tarball is notarized too, so Gatekeeper's online check passes, and Homebrew strips quarantine
# regardless.
#
# Credentials come from a notarytool keychain profile. There is no environment-variable password
# path, deliberately — secrets must not ride in the environment.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

TOOL_NAME="transcribe"
REPO_SLUG="drewster99/macos-transcribe"
TAP_SLUG="drewster99/homebrew-tap"
FORMULA_PATH="Formula/transcribe.rb"

PROJECT_REL="transcribe.xcodeproj"
SCHEME="transcribe"
CONFIGURATION="Release"
BUNDLE_IDENTIFIER="com.nuclearcyborg.transcribe"
TEAM_ID="P8MA38JTXY"
INSTALL_LOCATION="/usr/local/bin"
REQUIRED_ARCH="arm64"
MINIMUM_MACOS="26.0"

NOTARY_PROFILE="${NOTARY_PROFILE:-${NOTARYTOOL_PROFILE:-ncc-cli-notarytool}}"
NOTARIZATION_TIMEOUT="${NOTARIZATION_TIMEOUT:-30m}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="${REPO_ROOT}/${PROJECT_REL}/project.pbxproj"
WORK_DIR="${REPO_ROOT}/build/release"
DERIVED_DATA="${WORK_DIR}/DerivedData"
DIST_DIR="${WORK_DIR}/dist"
STAGING_DIR="${WORK_DIR}/staging"

# ─────────────────────────────────────────────────────────────────────────────
# Flags
# ─────────────────────────────────────────────────────────────────────────────

EXPLICIT_VERSION=""
SKIP_GITHUB=0
DRY_RUN=0
SKIP_TAP=0
ASSUME_YES=0
KEEP_WORK=0
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"

usage() {
    cat <<USAGE
Usage: ${0##*/} [options]

  --version X.Y.Z          Set the marketing version (default: bump the patch)
  --dry-run                Build, sign, notarize, and package, but do not tag, push, or publish
  --skip-github            Do everything except creating the GitHub release
  --skip-tap               Do not update the Homebrew formula
  --signing-identity NAME  Developer ID Application identity
  --installer-identity NAME Developer ID Installer identity
  --notary-profile NAME    notarytool keychain profile (default: ${NOTARY_PROFILE})
  --yes                    Do not prompt for confirmation
  --keep-work              Leave build/release in place afterwards
  -h, --help               Show this message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)            EXPLICIT_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --dry-run)            DRY_RUN=1; shift ;;
        --skip-github)        SKIP_GITHUB=1; shift ;;
        --skip-tap)           SKIP_TAP=1; shift ;;
        --signing-identity)   SIGNING_IDENTITY="${2:?}"; shift 2 ;;
        --installer-identity) INSTALLER_IDENTITY="${2:?}"; shift 2 ;;
        --notary-profile)     NOTARY_PROFILE="${2:?}"; shift 2 ;;
        --yes)                ASSUME_YES=1; shift ;;
        --keep-work)          KEEP_WORK=1; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────

step()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
die()   { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────

preflight() {
    step "Pre-flight checks"

    [[ -f "$PROJECT_FILE" ]] || die "Not found: $PROJECT_FILE"

    for tool in xcodebuild codesign pkgbuild productsign xcrun git plutil shasum lipo otool; do
        command -v "$tool" >/dev/null || die "Missing required tool: $tool"
    done
    if [[ $SKIP_GITHUB -eq 0 || $SKIP_TAP -eq 0 ]]; then
        command -v gh >/dev/null || die "Missing required tool: gh"
        gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
    fi

    # A dirty tree means the published binary would not match any commit.
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
        git -C "$REPO_ROOT" status --short
        die "Working tree is not clean. Commit or stash first."
    fi

    resolve_signing_identities
    verify_notary_credentials

    info "Signing:   $SIGNING_IDENTITY"
    info "Installer: $INSTALLER_IDENTITY"
    info "Notary:    $NOTARY_PROFILE"
}

# Both certificates are needed and they are different things: Developer ID Application signs the
# binary, Developer ID Installer signs the .pkg wrapping it. A .pkg signed with the Application cert
# (or with "3rd Party Mac Developer Installer", which is Mac App Store only) fails notarization.
resolve_signing_identities() {
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        local matches
        matches="$(security find-identity -v -p codesigning | grep 'Developer ID Application:' || true)"
        local count
        count="$(printf '%s\n' "$matches" | grep -c 'Developer ID Application:' || true)"
        [[ "$count" -eq 1 ]] || die "Expected exactly one Developer ID Application identity, found ${count:-0}. Use --signing-identity."
        SIGNING_IDENTITY="$(printf '%s\n' "$matches" | sed -E 's/.*"(.*)".*/\1/')"
    fi

    if [[ -z "$INSTALLER_IDENTITY" ]]; then
        local matches
        matches="$(security find-identity -v | grep 'Developer ID Installer:' || true)"
        local count
        count="$(printf '%s\n' "$matches" | grep -c 'Developer ID Installer:' || true)"
        if [[ "${count:-0}" -ne 1 ]]; then
            die "Expected exactly one Developer ID Installer identity, found ${count:-0}.
    A .pkg must be signed with a Developer ID Installer certificate; the Developer ID
    Application certificate cannot sign packages, and Mac Installer Distribution is for
    the Mac App Store only.
    Create one at https://developer.apple.com/account/resources/certificates
    (choose 'Developer ID Installer'), then double-click the downloaded .cer."
        fi
        INSTALLER_IDENTITY="$(printf '%s\n' "$matches" | sed -E 's/.*"(.*)".*/\1/')"
    fi
}

verify_notary_credentials() {
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notarytool profile '$NOTARY_PROFILE' is not usable.
    Create it with:
      xcrun notarytool store-credentials '$NOTARY_PROFILE' --apple-id <id> --team-id $TEAM_ID"
}

# ─────────────────────────────────────────────────────────────────────────────
# Versioning
# ─────────────────────────────────────────────────────────────────────────────

current_setting() {
    grep -m1 -E "^[[:space:]]*$1 = " "$PROJECT_FILE" | sed -E "s/.*$1 = ([^;]+);.*/\1/"
}

# Rewrites every occurrence and asserts the count, so a Debug/Release split-update cannot ship.
replace_setting() {
    local key="$1" value="$2"
    local before after
    before="$(grep -c -E "^[[:space:]]*$key = " "$PROJECT_FILE")"
    [[ "$before" -gt 0 ]] || die "Setting $key not found in project file"
    perl -pi -e "s/^(\s*)$key = [^;]+;/\${1}$key = $value;/" "$PROJECT_FILE"
    after="$(grep -c -E "^[[:space:]]*$key = $value;" "$PROJECT_FILE")"
    [[ "$after" -eq "$before" ]] || die "Expected to rewrite $before occurrences of $key, rewrote $after"
}

compute_version() {
    step "Version"

    local current_marketing current_build
    current_marketing="$(current_setting MARKETING_VERSION)"
    current_build="$(current_setting CURRENT_PROJECT_VERSION)"
    [[ -n "$current_marketing" ]] || die "MARKETING_VERSION not found"

    if [[ -n "$EXPLICIT_VERSION" ]]; then
        [[ "$EXPLICIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z, got '$EXPLICIT_VERSION'"
        NEW_VERSION="$EXPLICIT_VERSION"
    else
        local major minor patch
        IFS=. read -r major minor patch <<<"$current_marketing"
        [[ -n "${patch:-}" ]] || die "MARKETING_VERSION '$current_marketing' is not X.Y.Z; pass --version"
        NEW_VERSION="${major}.${minor}.$((patch + 1))"
    fi
    NEW_BUILD=$((current_build + 1))
    TAG="v${NEW_VERSION}"

    info "$current_marketing (build $current_build)  ->  $NEW_VERSION (build $NEW_BUILD)"

    if [[ $DRY_RUN -eq 0 ]]; then
        git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "Tag $TAG already exists locally."
        git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "Tag $TAG already exists on origin."
        if [[ $SKIP_GITHUB -eq 0 ]] && gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
            die "Release $TAG already exists."
        fi
    fi
}

apply_version() {
    [[ $DRY_RUN -eq 1 ]] && { info "Dry run: leaving the project file unchanged"; return; }
    replace_setting MARKETING_VERSION "$NEW_VERSION"
    replace_setting CURRENT_PROJECT_VERSION "$NEW_BUILD"
    plutil -lint "$PROJECT_FILE" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

build_tool() {
    step "Building $CONFIGURATION"

    # Guarded so an empty or unexpected WORK_DIR can never turn this into a destructive delete.
    case "$WORK_DIR" in
        "${REPO_ROOT}/build/"*) ;;
        *) die "Refusing to clear '$WORK_DIR': it is outside ${REPO_ROOT}/build" ;;
    esac
    rm -rf "$WORK_DIR"
    mkdir -p "$DERIVED_DATA" "$DIST_DIR" "$STAGING_DIR"

    # Built unsigned, then signed explicitly below, so the Developer ID identity is applied
    # deterministically rather than through whatever automatic signing resolves to.
    xcodebuild \
        -project "${REPO_ROOT}/${PROJECT_REL}" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'generic/platform=macOS' \
        CODE_SIGNING_ALLOWED=NO \
        clean build > "${WORK_DIR}/xcodebuild.log" 2>&1 \
        || { tail -40 "${WORK_DIR}/xcodebuild.log"; die "Build failed. Full log: ${WORK_DIR}/xcodebuild.log"; }

    BUILT_TOOL="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${TOOL_NAME}"
    [[ -f "$BUILT_TOOL" ]] || die "Built tool not found at $BUILT_TOOL"

    verify_built_product
}

# Reads one key from the Info.plist embedded in the binary's __TEXT,__info_plist section.
# `otool -P` prints two header lines before the XML, which plutil cannot parse, so the payload is
# isolated first.
embedded_plist_value() {
    otool -P "$BUILT_TOOL" | sed -n '/<?xml/,$p' | plutil -extract "$1" raw - 2>/dev/null || true
}

verify_built_product() {
    local archs
    archs="$(lipo -archs "$BUILT_TOOL" | tr -s ' ')"
    # Asserted rather than assumed: the speech models are Apple silicon only, so an x86_64 slice
    # would let an Intel Mac install this and then fail at runtime.
    [[ "$archs" == "$REQUIRED_ARCH" ]] || die "Expected architecture '$REQUIRED_ARCH', got '$archs'"

    local embedded_version embedded_identifier
    embedded_version="$(embedded_plist_value CFBundleShortVersionString)"
    embedded_identifier="$(embedded_plist_value CFBundleIdentifier)"

    if [[ $DRY_RUN -eq 0 ]]; then
        [[ "$embedded_version" == "$NEW_VERSION" ]] \
            || die "Embedded CFBundleShortVersionString is '$embedded_version', expected '$NEW_VERSION'"
    fi
    [[ "$embedded_identifier" == "$BUNDLE_IDENTIFIER" ]] \
        || die "Embedded CFBundleIdentifier is '$embedded_identifier', expected '$BUNDLE_IDENTIFIER'"

    # Without this the tool is terminated the moment it asks for Speech Recognition access.
    [[ -n "$(embedded_plist_value NSSpeechRecognitionUsageDescription)" ]] \
        || die "Embedded Info.plist is missing NSSpeechRecognitionUsageDescription"

    info "arch=$archs  version=$embedded_version  id=$embedded_identifier"
}

# ─────────────────────────────────────────────────────────────────────────────
# Signing
# ─────────────────────────────────────────────────────────────────────────────

sign_tool() {
    step "Signing"

    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$BUILT_TOOL"

    codesign --verify --strict --verbose=4 "$BUILT_TOOL" 2>&1 | sed 's/^/    /'

    # Captured into variables before matching. Piping directly into `grep -q` races: grep exits at
    # the first match, codesign takes SIGPIPE, and pipefail then reports the whole pipeline as
    # failed even though the match succeeded.
    local signature_details entitlements
    signature_details="$(codesign -dvvv "$BUILT_TOOL" 2>&1 || true)"
    entitlements="$(codesign -d --entitlements - --xml "$BUILT_TOOL" 2>/dev/null || true)"

    grep -q '^Authority=Developer ID Application' <<<"$signature_details" \
        || die "Binary is not signed with a Developer ID Application certificate"

    # Hardened runtime is a notarization requirement; get-task-allow would make the binary
    # debuggable and is rejected.
    grep -q 'flags=.*runtime' <<<"$signature_details" \
        || die "Hardened runtime flag is not set on the signed binary"

    if grep -q 'get-task-allow' <<<"$entitlements"; then
        die "Binary carries get-task-allow, which notarization rejects"
    fi

    info "signed and verified"
}

# ─────────────────────────────────────────────────────────────────────────────
# Notarization
# ─────────────────────────────────────────────────────────────────────────────

notarize() {
    local artifact="$1" label="$2"
    step "Notarizing $label"

    local submission="${WORK_DIR}/notarize-${label}.json"
    xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout "$NOTARIZATION_TIMEOUT" \
        --output-format json > "$submission" 2>&1 \
        || { cat "$submission"; die "notarytool submit failed for $label"; }

    local status submission_id
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$submission" 2>/dev/null || true)"
    submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$submission" 2>/dev/null || true)"

    if [[ "$status" != "Accepted" ]]; then
        warn "Notarization status: ${status:-unknown}"
        [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
        die "Notarization of $label was not accepted"
    fi
    info "accepted (id $submission_id)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Packaging
# ─────────────────────────────────────────────────────────────────────────────

make_tarball() {
    step "Building tarball"

    TARBALL_NAME="${TOOL_NAME}-${NEW_VERSION}-macos-${REQUIRED_ARCH}.tar.gz"
    TARBALL_PATH="${DIST_DIR}/${TARBALL_NAME}"

    # Notarized as a zip so the ticket exists for Gatekeeper's online check. A bare Mach-O cannot be
    # stapled, so an offline machine relies on the .pkg or on Homebrew clearing quarantine.
    local zip_path="${WORK_DIR}/${TOOL_NAME}-notarize.zip"
    ditto -c -k --keepParent "$BUILT_TOOL" "$zip_path"
    notarize "$zip_path" "binary"

    tar -czf "$TARBALL_PATH" -C "$(dirname "$BUILT_TOOL")" "$TOOL_NAME"
    info "$TARBALL_NAME ($(du -h "$TARBALL_PATH" | cut -f1))"
}

make_package() {
    step "Building package"

    PKG_NAME="${TOOL_NAME}-${NEW_VERSION}.pkg"
    PKG_PATH="${DIST_DIR}/${PKG_NAME}"
    local unsigned_pkg="${WORK_DIR}/${TOOL_NAME}-unsigned.pkg"

    install -m 0755 "$BUILT_TOOL" "${STAGING_DIR}/${TOOL_NAME}"

    pkgbuild \
        --root "$STAGING_DIR" \
        --identifier "$BUNDLE_IDENTIFIER" \
        --version "$NEW_VERSION" \
        --install-location "$INSTALL_LOCATION" \
        "$unsigned_pkg" >/dev/null

    productsign --sign "$INSTALLER_IDENTITY" "$unsigned_pkg" "$PKG_PATH" >/dev/null
    pkgutil --check-signature "$PKG_PATH" | sed 's/^/    /'

    notarize "$PKG_PATH" "pkg"

    # Unlike a bare binary, a .pkg can carry a stapled ticket, so this install path works offline.
    xcrun stapler staple "$PKG_PATH"
    xcrun stapler validate "$PKG_PATH"

    info "$PKG_NAME ($(du -h "$PKG_PATH" | cut -f1))"
}

make_checksums() {
    step "Checksums"
    ( cd "$DIST_DIR" && shasum -a 256 "$PKG_NAME" "$TARBALL_NAME" > SHA256SUMS )
    TARBALL_SHA="$(awk -v f="$TARBALL_NAME" '$2==f {print $1}' "${DIST_DIR}/SHA256SUMS")"
    [[ -n "$TARBALL_SHA" ]] || die "Could not compute tarball checksum"
    sed 's/^/    /' "${DIST_DIR}/SHA256SUMS"
}

# ─────────────────────────────────────────────────────────────────────────────
# Publishing
# ─────────────────────────────────────────────────────────────────────────────

release_notes() {
    NOTES_FILE="${WORK_DIR}/RELEASE_NOTES_${NEW_VERSION}.md"
    local previous
    previous="$(git -C "$REPO_ROOT" tag --list 'v*' --sort=-v:refname | head -1)"

    {
        echo "## Install"
        echo
        echo '```'
        echo "brew install ${TAP_SLUG%/homebrew-tap}/tap/${TOOL_NAME}"
        echo '```'
        echo
        echo "Or download \`${PKG_NAME}\` below, which installs \`${TOOL_NAME}\` to \`${INSTALL_LOCATION}\`."
        echo "\`${TARBALL_NAME}\` contains the bare binary."
        echo
        echo "Requires macOS ${MINIMUM_MACOS} or later on Apple silicon. Signed and notarized by Apple."
        echo
        echo "## Changes"
        echo
        if [[ -n "$previous" ]]; then
            git -C "$REPO_ROOT" log --pretty='- %s (%h)' "${previous}..HEAD"
        else
            git -C "$REPO_ROOT" log --pretty='- %s (%h)' -20
        fi
    } > "$NOTES_FILE"
}

publish() {
    step "Publishing $TAG"

    git -C "$REPO_ROOT" add "$PROJECT_FILE"
    git -C "$REPO_ROOT" commit -m "Release ${NEW_VERSION}" >/dev/null
    git -C "$REPO_ROOT" tag -a "$TAG" -m "Release ${NEW_VERSION}"
    git -C "$REPO_ROOT" push origin HEAD:main
    git -C "$REPO_ROOT" push origin "$TAG"

    release_notes
    gh release create "$TAG" \
        "$PKG_PATH" "$TARBALL_PATH" "${DIST_DIR}/SHA256SUMS" \
        --repo "$REPO_SLUG" \
        --title "${TOOL_NAME} ${NEW_VERSION}" \
        --notes-file "$NOTES_FILE"

    verify_published
}

verify_published() {
    local view="${WORK_DIR}/release-${NEW_VERSION}.json"
    gh release view "$TAG" --repo "$REPO_SLUG" --json tagName,url,assets > "$view"

    grep -q "\"$TAG\"" "$view" || die "Published release is missing tag $TAG"
    for asset in "$PKG_NAME" "$TARBALL_NAME" "SHA256SUMS"; do
        grep -q "$asset" "$view" || die "Published release is missing asset $asset"
    done
    info "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$view")"
}

update_tap() {
    [[ $SKIP_TAP -eq 1 ]] && { info "Skipping tap update"; return; }
    step "Updating Homebrew formula"

    local tap_dir="${WORK_DIR}/tap"
    gh repo clone "$TAP_SLUG" "$tap_dir" -- --quiet 2>/dev/null || die "Could not clone $TAP_SLUG"
    mkdir -p "$(dirname "${tap_dir}/${FORMULA_PATH}")"

    cat > "${tap_dir}/${FORMULA_PATH}" <<FORMULA
class Transcribe < Formula
  desc "Transcribe audio and video files using on-device speech recognition"
  homepage "https://github.com/${REPO_SLUG}"
  url "https://github.com/${REPO_SLUG}/releases/download/${TAG}/${TARBALL_NAME}"
  sha256 "${TARBALL_SHA}"
  license "MIT"
  # Stated explicitly: the asset name carries the platform and architecture, so Homebrew cannot
  # infer the version from the URL.
  version "${NEW_VERSION}"

  # The on-device speech models are Apple silicon only, and SpeechAnalyzer requires macOS 26.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    bin.install "transcribe"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/transcribe --version")

    # Every supported locale is a BCP-47 tag, so the listing must name at least one.
    assert_match(/[a-z]{2}-[A-Z]{2}/, shell_output("#{bin}/transcribe --list-locales"))

    # A missing file must exit 66, not merely print something.
    shell_output("#{bin}/transcribe #{testpath}/absent.m4a 2>&1", 66)

    # A file that is not media must be rejected as unusable input rather than transcribed.
    (testpath/"notes.mp4").write("this is not a video")
    shell_output("#{bin}/transcribe #{testpath}/notes.mp4 2>&1", 65)
  end
end
FORMULA

    git -C "$tap_dir" add "$FORMULA_PATH"
    if git -C "$tap_dir" diff --cached --quiet; then
        info "Formula already up to date"
        return
    fi
    git -C "$tap_dir" commit -m "transcribe ${NEW_VERSION}" >/dev/null
    git -C "$tap_dir" push >/dev/null
    info "brew install ${TAP_SLUG%/homebrew-tap}/tap/${TOOL_NAME}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    preflight
    compute_version

    if [[ $DRY_RUN -eq 1 ]]; then
        warn "Dry run: nothing will be committed, tagged, pushed, or published."
    else
        confirm "Release ${TOOL_NAME} ${NEW_VERSION} to ${REPO_SLUG}?"
    fi

    apply_version
    build_tool
    sign_tool
    make_tarball
    make_package
    make_checksums

    if [[ $DRY_RUN -eq 1 ]]; then
        step "Dry run complete"
        info "Artifacts: $DIST_DIR"
        ls -la "$DIST_DIR" | sed 's/^/    /'
        return
    fi

    if [[ $SKIP_GITHUB -eq 1 ]]; then
        warn "Skipping GitHub release; artifacts are in $DIST_DIR"
    else
        publish
        update_tap
    fi

    step "Released ${TOOL_NAME} ${NEW_VERSION}"
    [[ $KEEP_WORK -eq 1 ]] || rm -rf "$DERIVED_DATA" "$STAGING_DIR"
}

main "$@"
