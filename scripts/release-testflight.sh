#!/usr/bin/env bash
set -euo pipefail

: "${APPLE_TEAM_ID:?Configure APPLE_TEAM_ID in the testflight environment}"
: "${APP_STORE_CONNECT_KEY_ID:?Configure APP_STORE_CONNECT_KEY_ID}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Configure APP_STORE_CONNECT_ISSUER_ID}"
: "${APP_STORE_CONNECT_KEY_P8_BASE64:?Configure APP_STORE_CONNECT_KEY_P8_BASE64}"
: "${HARBOR_API_URL:?Configure HARBOR_API_URL}"
: "${GITHUB_RUN_NUMBER:?Run this script from GitHub Actions}"
: "${GITHUB_RUN_ATTEMPT:?Run this script from GitHub Actions}"

cd "$(dirname "$0")/../apps/mobile"
umask 077
release_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xlgw-testflight.XXXXXX")"
app_plist=ios/Runner/Info.plist
cleanup() {
  if [[ -f "$release_dir/original-info.plist" ]]; then
    cp -p "$release_dir/original-info.plist" "$app_plist"
  fi
  rm -rf -- "$release_dir"
}
trap cleanup EXIT
cp -p "$app_plist" "$release_dir/original-info.plist"

python3 - "$app_plist" "$release_dir/export-options.plist" <<'PY'
import base64
import os
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

api_url = os.environ["HARBOR_API_URL"]
try:
    url = urlsplit(api_url)
    if (
        re.search(r"\s", api_url)
        or url.scheme not in {"http", "https"}
        or not url.hostname
        or url.username is not None
        or url.password is not None
        or url.query
        or url.fragment
        or url.port == 0
    ):
        raise ValueError
except ValueError:
    sys.exit("HARBOR_API_URL must be an HTTP or HTTPS URL without credentials, query, or fragment.")

# Xcode can log the host separately or emit the Flutter define in base64.
encoded_define = base64.b64encode(f"HARBOR_API_URL={api_url}".encode()).decode()
for value in (url.hostname, encoded_define):
    print(f"::add-mask::{value.replace('%', '%25')}")

app_plist = Path(sys.argv[1])
if url.scheme == "http":
    metadata = plistlib.loads(app_plist.read_bytes())
    ats = metadata.setdefault("NSAppTransportSecurity", {})
    domains = ats.setdefault("NSExceptionDomains", {})
    exception = domains.setdefault(url.hostname, {})
    exception["NSExceptionAllowsInsecureHTTPLoads"] = True
    app_plist.write_bytes(plistlib.dumps(metadata, sort_keys=False))

export_options = {
    "destination": "upload",
    "method": "app-store-connect",
    "signingStyle": "automatic",
    "teamID": os.environ["APPLE_TEAM_ID"],
    "manageAppVersionAndBuildNumber": False,
    "testFlightInternalTestingOnly": True,
    "uploadSymbols": True,
}
Path(sys.argv[2]).write_bytes(plistlib.dumps(export_options))
PY

key_file="$release_dir/app-store-connect.p8"
printf '%s' "$APP_STORE_CONNECT_KEY_P8_BASE64" | base64 -D > "$key_file"
unset APP_STORE_CONNECT_KEY_P8_BASE64

# Reserve low build numbers for the manually uploaded predecessors.
build_number="$((3 + GITHUB_RUN_NUMBER / 100)).$((GITHUB_RUN_NUMBER % 100)).$GITHUB_RUN_ATTEMPT"
archive_path="$release_dir/Runner.xcarchive"
auth=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$key_file"
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
)
flutter build ios --config-only --release --no-pub --no-codesign --build-number="$build_number" \
  --dart-define="HARBOR_API_URL=$HARBOR_API_URL"
unset HARBOR_API_URL

xcodebuild -quiet archive -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "${auth[@]}"

archive_plist="$archive_path/Products/Applications/Runner.app/Info.plist"
test "$(plutil -extract CFBundleIdentifier raw "$archive_plist")" = dev.oines.xlgw
test "$(plutil -extract CFBundleDisplayName raw "$archive_plist")" = 心灵港湾
test "$(plutil -extract CFBundleVersion raw "$archive_plist")" = "$build_number"
test "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$archive_plist")" = false
version="$(plutil -extract CFBundleShortVersionString raw "$archive_plist")"

xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$release_dir/export" \
  -exportOptionsPlist "$release_dir/export-options.plist" "${auth[@]}"
printf 'Uploaded iOS %s (%s) to TestFlight for internal testing.\n' "$version" "$build_number"
