#!/bin/bash
# Prepare or publish a Lychee release.
#
# Unsigned distribution (current workflow):
#   ./release.sh prepare 1.2.0 --unsigned
#   ./release.sh publish-assets 1.2.0
#   # Review releases/appcast-1.2.0.xml, merge it as appcast.xml, then:
#   ./release.sh sync-legacy-feeds 1.2.0
#
# Developer ID distribution (future workflow):
#   ./release.sh prepare 1.2.0 --developer-id /path/to/Lychee.app
#   ./release.sh publish-assets 1.2.0
#   # Review releases/appcast-1.2.0.xml, merge it as appcast.xml, then:
#   ./release.sh sync-legacy-feeds 1.2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_REPO="rishabhbs/Lychee-Lyrics-in-MenuBar"
PUBLIC_APPCAST_URL="https://raw.githubusercontent.com/${PUBLIC_REPO}/main/appcast.xml"
EXPECTED_BUNDLE_ID="personal.dev.Lychee"
EXPECTED_TEAM_ID="NM7GSM2R53"
EXPECTED_PUBLIC_KEY="GzFgyS6mT5HKmpbAcXG0315b0JuSCLc5jSKA8zBCbbI="
EXPECTED_SPARKLE_VERSION="2.9.5"
LEGACY_FEED_REPOS=("rishabhbs/Lychee-Releases")
RELEASES_DIR="$SCRIPT_DIR/releases"
LIVE_APPCAST_PATH="$SCRIPT_DIR/appcast.xml"
BUILD_DIR=""

usage() {
  cat <<'EOF'
Usage:
  ./release.sh prepare <version> --unsigned
  ./release.sh prepare <version> --developer-id <path-to-exported-Lychee.app>
  ./release.sh publish-assets <version>
  ./release.sh sync-legacy-feeds <version>

prepare validates the source and app, creates signed update artifacts, and writes
an ignored candidate feed under releases/ without changing GitHub.

publish-assets validates the prepared artifacts and creates the GitHub release.
It does not modify any update feed. Merge the candidate feed as appcast.xml only
after the release assets exist and have been tested.

sync-legacy-feeds verifies that the candidate is already live on main, then mirrors
it to the old update-feed repositories for earlier Lychee installations.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
  fi
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "Required tool '$1' is not installed"
}

validate_version() {
  if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    fail "Version must be a valid semantic version, such as 1.2.0"
  fi
}

ensure_source_ready() {
  [ "$(git -C "$SCRIPT_DIR" branch --show-current)" = "main" ] || \
    fail "Releases must be prepared from the main branch"
  [ -z "$(git -C "$SCRIPT_DIR" status --porcelain)" ] || \
    fail "Commit or discard all source changes before preparing a release"

  git -C "$SCRIPT_DIR" fetch origin main
  [ "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" = "$(git -C "$SCRIPT_DIR" rev-parse origin/main)" ] || \
    fail "Local main must exactly match origin/main"
}

find_sign_update() {
  local preferred_root="${1:-}"
  local tool=""

  if [ -n "$preferred_root" ]; then
    tool=$(find "$preferred_root" \
      -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
      -type f -perm -u+x -print -quit 2>/dev/null || true)
  fi
  if [ -z "$tool" ]; then
    tool=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
      -type f -perm -u+x -print -quit 2>/dev/null || true)
  fi
  [ -n "$tool" ] || fail "Sparkle sign_update was not found. Build Lychee once in Xcode."
  printf '%s\n' "$tool"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

validate_entitlements() {
  local app_path="$1"
  local signing_mode="$2"
  local entitlements_file
  local apple_events
  local library_validation_disabled
  entitlements_file=$(mktemp "${TMPDIR:-/tmp}/lychee-entitlements.XXXXXX")

  if ! codesign -d --entitlements :- "$app_path" 2>&1 | \
    sed -n '/^<?xml/,$p' > "$entitlements_file"; then
    rm -f "$entitlements_file"
    fail "Could not read app entitlements"
  fi
  plutil -lint "$entitlements_file" >/dev/null || {
    rm -f "$entitlements_file"
    fail "App entitlements are not a valid property list"
  }

  apple_events=$(/usr/libexec/PlistBuddy \
    -c "Print :com.apple.security.automation.apple-events" \
    "$entitlements_file" 2>/dev/null || true)
  [ "$apple_events" = "true" ] || {
    rm -f "$entitlements_file"
    fail "The app is missing its Apple Events automation entitlement"
  }

  if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" \
    "$entitlements_file" >/dev/null 2>&1; then
    rm -f "$entitlements_file"
    fail "Release app contains the debug-only get-task-allow entitlement"
  fi

  library_validation_disabled=$(/usr/libexec/PlistBuddy \
    -c "Print :com.apple.security.cs.disable-library-validation" \
    "$entitlements_file" 2>/dev/null || true)
  if [ "$signing_mode" = "unsigned" ]; then
    [ "$library_validation_disabled" = "true" ] || {
      rm -f "$entitlements_file"
      fail "Unsigned app must disable library validation to load embedded Sparkle"
    }
  elif [ -n "$library_validation_disabled" ]; then
    rm -f "$entitlements_file"
    fail "Developer ID app must not disable library validation"
  fi

  rm -f "$entitlements_file"
}

validate_release_binary() {
  local executable="$1"
  local architectures
  local marker
  architectures=$(lipo -archs "$executable")

  for architecture in arm64 x86_64; do
    [[ " $architectures " == *" $architecture "* ]] || \
      fail "Release executable is missing the $architecture architecture"
  done

  for marker in \
    "Open Algorithm Debug" \
    "Onboarding Done?" \
    "letmein" \
    "algo_debug_history" \
    "perf_sessions" \
    "[LRCLib]" \
    "[LyricsCache]"; do
    if strings "$executable" | grep -F "$marker" >/dev/null; then
      fail "Release executable contains Debug-only marker: $marker"
    fi
  done

  if strings "$executable" | grep -E '/Users/[^/]+/' >/dev/null; then
    fail "Release executable contains a local macOS user path; verify Release stripping settings"
  fi
}

validate_app() {
  local app_path="$1"
  local signing_mode="$2"
  local info_plist="$app_path/Contents/Info.plist"
  local executable="$app_path/Contents/MacOS/Lychee"
  local sparkle_info="$app_path/Contents/Frameworks/Sparkle.framework/Versions/Current/Resources/Info.plist"
  local signing_info
  local team_id
  local sparkle_version

  [ -d "$app_path" ] || fail "App bundle not found: $app_path"
  [ -f "$info_plist" ] || fail "App bundle has no Info.plist"
  [ -x "$executable" ] || fail "App bundle has no Lychee executable"
  [ -f "$sparkle_info" ] || fail "App bundle has no embedded Sparkle framework"

  BUILD_NUMBER=$(plist_value "$info_plist" CFBundleVersion)
  APP_VERSION=$(plist_value "$info_plist" CFBundleShortVersionString)
  BUNDLE_ID=$(plist_value "$info_plist" CFBundleIdentifier)
  APP_FEED_URL=$(plist_value "$info_plist" SUFeedURL)
  APP_PUBLIC_KEY=$(plist_value "$info_plist" SUPublicEDKey)
  sparkle_version=$(plist_value "$sparkle_info" CFBundleShortVersionString)

  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "App build number must be numeric"
  [ "$APP_VERSION" = "$VERSION" ] || \
    fail "Requested version $VERSION does not match app version $APP_VERSION"
  [ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || \
    fail "Unexpected bundle identifier: $BUNDLE_ID"
  [ "$APP_FEED_URL" = "$PUBLIC_APPCAST_URL" ] || \
    fail "App points to the wrong Sparkle feed: $APP_FEED_URL"
  [ "$APP_PUBLIC_KEY" = "$EXPECTED_PUBLIC_KEY" ] || \
    fail "App contains the wrong Sparkle public key"
  [ "$sparkle_version" = "$EXPECTED_SPARKLE_VERSION" ] || \
    fail "Expected Sparkle $EXPECTED_SPARKLE_VERSION, found $sparkle_version"

  codesign --verify --deep --strict --verbose=2 "$app_path" || \
    fail "App or an embedded Sparkle component has an invalid code signature"
  signing_info=$(codesign -dv --verbose=4 "$app_path" 2>&1)
  printf '%s\n' "$signing_info" | grep -q 'flags=.*runtime' || \
    fail "App is missing Hardened Runtime"

  validate_entitlements "$app_path" "$signing_mode"
  validate_release_binary "$executable"

  case "$signing_mode" in
    unsigned)
      printf '%s\n' "$signing_info" | grep -q '^Signature=adhoc$' || \
        fail "Unsigned releases must use an ad-hoc signature"
      team_id=$(printf '%s\n' "$signing_info" | sed -n 's/^TeamIdentifier=//p')
      [ "$team_id" = "not set" ] || fail "Unsigned release unexpectedly has Team ID: $team_id"
      if spctl --assess --type execute "$app_path" >/dev/null 2>&1; then
        fail "Unsigned app was unexpectedly accepted by Gatekeeper"
      fi
      ;;
    developer-id)
      team_id=$(printf '%s\n' "$signing_info" | sed -n 's/^TeamIdentifier=//p')
      [ "$team_id" = "$EXPECTED_TEAM_ID" ] || \
        fail "App is signed by unexpected team: $team_id"
      printf '%s\n' "$signing_info" | grep -q '^Authority=Developer ID Application:' || \
        fail "App is not signed for Developer ID distribution"
      spctl --assess --type execute --verbose=2 "$app_path" || \
        fail "Gatekeeper rejected the Developer ID app; notarize it before preparing"
      ;;
    *)
      fail "Unknown signing mode: $signing_mode"
      ;;
  esac
}

build_unsigned_app() {
  require_tool xcodebuild
  BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/LycheeRelease.XXXXXX")

  echo "[1/5] Building universal ad-hoc Release app..."
  xcodebuild \
    -project "$SCRIPT_DIR/Lychee.xcodeproj" \
    -scheme Lychee \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_ENTITLEMENTS="$SCRIPT_DIR/Lychee/LycheeUnsigned.entitlements" \
    DEVELOPMENT_TEAM= \
    clean build

  APP_PATH="$BUILD_DIR/Build/Products/Release/Lychee.app"
}

prepare_release() {
  local signing_mode="$1"
  local supplied_app_path="${2:-}"
  local sign_update
  local candidate_appcast_path="$RELEASES_DIR/appcast-${VERSION}.xml"
  local zip_name="Lychee-${VERSION}.zip"
  local dmg_name="Lychee-${VERSION}.dmg"
  local zip_path="$RELEASES_DIR/$zip_name"
  local dmg_path="$RELEASES_DIR/$dmg_name"
  local stable_dmg_path="$RELEASES_DIR/Lychee.dmg"
  local public_release_url="https://github.com/${PUBLIC_REPO}/releases/download/v${VERSION}/${zip_name}"
  local sign_output
  local ed_signature
  local file_size
  local pubdate

  for tool in codesign create-dmg ditto hdiutil lipo plutil spctl strings unzip xmllint; do
    require_tool "$tool"
  done
  ensure_source_ready

  if [ "$signing_mode" = "unsigned" ]; then
    [ -z "$supplied_app_path" ] || fail "--unsigned builds Lychee from source and takes no app path"
    build_unsigned_app
    sign_update=$(find_sign_update "$BUILD_DIR")
  else
    [ -n "$supplied_app_path" ] || fail "--developer-id requires a path to an exported app"
    APP_PATH="$supplied_app_path"
    sign_update=$(find_sign_update)
  fi

  echo "[2/5] Validating app identity, architecture, entitlements, and signature..."
  validate_app "$APP_PATH" "$signing_mode"

  mkdir -p "$RELEASES_DIR"
  rm -f "$zip_path" "$dmg_path" "$stable_dmg_path"

  echo "[3/5] Creating and verifying $zip_name..."
  ditto -c -k --keepParent "$APP_PATH" "$zip_path"
  unzip -tq "$zip_path" >/dev/null || fail "Created ZIP failed integrity verification"
  file_size=$(stat -f%z "$zip_path")

  sign_output=$("$sign_update" "$zip_path" 2>&1)
  ed_signature=$(printf '%s\n' "$sign_output" | \
    sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
  [ -n "$ed_signature" ] || {
    printf '%s\n' "$sign_output" >&2
    fail "Could not create the Sparkle EdDSA signature"
  }
  "$sign_update" --verify "$zip_path" "$ed_signature" >/dev/null || \
    fail "Sparkle rejected the newly created update signature"

  echo "[4/5] Creating and verifying $dmg_name..."
  create-dmg \
    --volname "Lychee" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "Lychee.app" 140 190 \
    --hide-extension "Lychee.app" \
    --app-drop-link 400 190 \
    "$dmg_path" \
    "$APP_PATH"
  hdiutil verify "$dmg_path" >/dev/null || fail "Created DMG failed integrity verification"
  cp "$dmg_path" "$stable_dmg_path"
  cmp -s "$dmg_path" "$stable_dmg_path" || fail "Stable DMG alias does not match versioned DMG"

  echo "[5/5] Writing and validating the candidate appcast..."
  pubdate=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
  cat > "$candidate_appcast_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Lychee</title>
        <link>${PUBLIC_APPCAST_URL}</link>
        <language>en</language>
        <item>
            <title>Lychee ${VERSION}</title>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <pubDate>${pubdate}</pubDate>
            <enclosure
                url="${public_release_url}"
                sparkle:edSignature="${ed_signature}"
                length="${file_size}"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
EOF
  xmllint --noout "$candidate_appcast_path" || fail "Generated appcast is not valid XML"

  echo ""
  echo "Prepared Lychee $VERSION (build $BUILD_NUMBER, $signing_mode)."
  echo "ZIP: $zip_path"
  echo "DMG: $dmg_path"
  echo "Stable website DMG: $stable_dmg_path"
  echo "Candidate feed: $candidate_appcast_path"
  echo "No GitHub release or update feed was changed. Test the artifacts before publishing assets."
}

xml_value() {
  xmllint --xpath "string($2)" "$1"
}

publish_assets() {
  local zip_name="Lychee-${VERSION}.zip"
  local dmg_name="Lychee-${VERSION}.dmg"
  local zip_path="$RELEASES_DIR/$zip_name"
  local dmg_path="$RELEASES_DIR/$dmg_name"
  local stable_dmg_path="$RELEASES_DIR/Lychee.dmg"
  local candidate_appcast_path="$RELEASES_DIR/appcast-${VERSION}.xml"
  local expected_url="https://github.com/${PUBLIC_REPO}/releases/download/v${VERSION}/${zip_name}"
  local appcast_version
  local appcast_url
  local appcast_signature
  local appcast_length
  local actual_length
  local sign_update
  local assets

  for tool in cmp gh hdiutil unzip xmllint; do
    require_tool "$tool"
  done
  ensure_source_ready
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login"

  [ -f "$candidate_appcast_path" ] || fail "Candidate appcast is missing; run prepare first"
  [ -f "$zip_path" ] || fail "Prepared ZIP is missing: $zip_path"
  [ -f "$dmg_path" ] || fail "Prepared DMG is missing: $dmg_path"
  [ -f "$stable_dmg_path" ] || fail "Stable website DMG is missing: $stable_dmg_path"

  xmllint --noout "$candidate_appcast_path" || fail "Candidate appcast is not valid XML"
  appcast_version=$(xml_value "$candidate_appcast_path" "//*[local-name()='shortVersionString']")
  appcast_url=$(xml_value "$candidate_appcast_path" "//*[local-name()='enclosure']/@url")
  appcast_signature=$(xml_value "$candidate_appcast_path" "//*[local-name()='enclosure']/@*[local-name()='edSignature']")
  appcast_length=$(xml_value "$candidate_appcast_path" "//*[local-name()='enclosure']/@length")
  actual_length=$(stat -f%z "$zip_path")

  [ "$appcast_version" = "$VERSION" ] || fail "Candidate appcast describes version $appcast_version"
  [ "$appcast_url" = "$expected_url" ] || fail "Candidate appcast contains the wrong release URL"
  [ "$appcast_length" = "$actual_length" ] || fail "Candidate appcast ZIP length does not match prepared ZIP"
  [ -n "$appcast_signature" ] || fail "Candidate appcast has no Sparkle EdDSA signature"

  unzip -tq "$zip_path" >/dev/null || fail "Prepared ZIP failed integrity verification"
  hdiutil verify "$dmg_path" >/dev/null || fail "Prepared DMG failed integrity verification"
  cmp -s "$dmg_path" "$stable_dmg_path" || fail "Stable DMG alias does not match versioned DMG"
  sign_update=$(find_sign_update)
  "$sign_update" --verify "$zip_path" "$appcast_signature" >/dev/null || \
    fail "Sparkle rejected the prepared update signature"

  echo "Publishing GitHub release v${VERSION}..."
  if gh release view "v${VERSION}" --repo "$PUBLIC_REPO" >/dev/null 2>&1; then
    gh release upload "v${VERSION}" "$zip_path" "$dmg_path" "$stable_dmg_path" \
      --clobber --repo "$PUBLIC_REPO"
  else
    gh release create "v${VERSION}" "$zip_path" "$dmg_path" "$stable_dmg_path" \
      --repo "$PUBLIC_REPO" \
      --title "Lychee ${VERSION}" \
      --generate-notes
  fi

  assets=$(gh release view "v${VERSION}" --repo "$PUBLIC_REPO" --json assets --jq '.assets[].name')
  for asset in "$zip_name" "$dmg_name" "Lychee.dmg"; do
    printf '%s\n' "$assets" | grep -Fxq "$asset" || fail "GitHub release is missing $asset"
  done

  echo ""
  echo "Published release assets: https://github.com/${PUBLIC_REPO}/releases/tag/v${VERSION}"
  echo "Website download: https://github.com/${PUBLIC_REPO}/releases/latest/download/Lychee.dmg"
  echo "No update feed was changed. Review $candidate_appcast_path, then merge it as appcast.xml."
}

sync_legacy_feeds() {
  local candidate_appcast_path="$RELEASES_DIR/appcast-${VERSION}.xml"
  local appcast_version
  local encoded_appcast
  local legacy_repo
  local legacy_sha
  local assets

  for tool in cmp gh xmllint; do
    require_tool "$tool"
  done
  ensure_source_ready
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login"

  [ -f "$candidate_appcast_path" ] || fail "Candidate appcast is missing; run prepare first"
  [ -f "$LIVE_APPCAST_PATH" ] || fail "The live appcast.xml is missing"
  xmllint --noout "$candidate_appcast_path" || fail "Candidate appcast is not valid XML"
  xmllint --noout "$LIVE_APPCAST_PATH" || fail "Live appcast.xml is not valid XML"
  cmp -s "$candidate_appcast_path" "$LIVE_APPCAST_PATH" || \
    fail "appcast.xml on main must exactly match the prepared candidate before legacy feeds are changed"

  appcast_version=$(xml_value "$LIVE_APPCAST_PATH" "//*[local-name()='shortVersionString']")
  [ "$appcast_version" = "$VERSION" ] || fail "Live appcast.xml describes version $appcast_version"

  assets=$(gh release view "v${VERSION}" --repo "$PUBLIC_REPO" --json assets --jq '.assets[].name') || \
    fail "GitHub release v${VERSION} does not exist; publish assets first"
  for asset in "Lychee-${VERSION}.zip" "Lychee-${VERSION}.dmg" "Lychee.dmg"; do
    printf '%s\n' "$assets" | grep -Fxq "$asset" || fail "GitHub release is missing $asset"
  done

  encoded_appcast=$(base64 < "$LIVE_APPCAST_PATH" | tr -d '\n')
  for legacy_repo in "${LEGACY_FEED_REPOS[@]}"; do
    echo "Mirroring appcast to $legacy_repo for existing installations..."
    if legacy_sha=$(gh api "repos/${legacy_repo}/contents/appcast.xml" --jq .sha 2>/dev/null); then
      gh api --method PUT "repos/${legacy_repo}/contents/appcast.xml" \
        -f message="Release v${VERSION}" \
        -f content="$encoded_appcast" \
        -f sha="$legacy_sha" \
        -f branch="main" >/dev/null
    else
      gh api --method PUT "repos/${legacy_repo}/contents/appcast.xml" \
        -f message="Release v${VERSION}" \
        -f content="$encoded_appcast" \
        -f branch="main" >/dev/null
    fi
  done

  echo "Legacy feeds now point to Lychee $VERSION."
}

ACTION="${1:-}"
VERSION="${2:-}"

case "$ACTION" in
  prepare)
    [ -n "$VERSION" ] || { usage; exit 1; }
    validate_version "$VERSION"
    case "${3:-}" in
      --unsigned)
        [ "$#" -eq 3 ] || { usage; exit 1; }
        prepare_release unsigned
        ;;
      --developer-id)
        [ "$#" -eq 4 ] || { usage; exit 1; }
        prepare_release developer-id "$4"
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  publish-assets)
    [ "$#" -eq 2 ] || { usage; exit 1; }
    validate_version "$VERSION"
    publish_assets
    ;;
  sync-legacy-feeds)
    [ "$#" -eq 2 ] || { usage; exit 1; }
    validate_version "$VERSION"
    sync_legacy_feeds
    ;;
  *)
    usage
    exit 1
    ;;
esac
