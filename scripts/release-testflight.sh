#!/usr/bin/env bash
set -euo pipefail

: "${APPLE_TEAM_ID:?Configure APPLE_TEAM_ID in the testflight environment}"
: "${APP_STORE_CONNECT_KEY_ID:?Configure APP_STORE_CONNECT_KEY_ID}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Configure APP_STORE_CONNECT_ISSUER_ID}"
: "${APP_STORE_CONNECT_KEY_P8_BASE64:?Configure APP_STORE_CONNECT_KEY_P8_BASE64}"
: "${APPLE_DISTRIBUTION_P12_BASE64:?Configure APPLE_DISTRIBUTION_P12_BASE64}"
: "${APPLE_DISTRIBUTION_P12_PASSWORD:?Configure APPLE_DISTRIBUTION_P12_PASSWORD}"
: "${APPLE_APP_STORE_PROFILE_BASE64:?Configure APPLE_APP_STORE_PROFILE_BASE64}"
: "${HARBOR_API_URL:?Configure HARBOR_API_URL}"
: "${GITHUB_RUN_NUMBER:?Run this script from GitHub Actions}"
: "${GITHUB_RUN_ATTEMPT:?Run this script from GitHub Actions}"

cd "$(dirname "$0")/../apps/mobile"
umask 077
release_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xlgw-testflight.XXXXXX")"
app_plist=ios/Runner/Info.plist
bundle_id=dev.oines.xlgw
installed_profiles=()
signing_keychain="$release_dir/signing.keychain-db"
cleanup() {
  if [[ -f "$release_dir/original-info.plist" ]]; then
    cp -p "$release_dir/original-info.plist" "$app_plist"
  fi
  for profile_path in ${installed_profiles[@]+"${installed_profiles[@]}"}; do
    rm -f -- "$profile_path"
  done
  if [[ -f "$signing_keychain" ]]; then
    security delete-keychain "$signing_keychain" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$release_dir"
}
trap cleanup EXIT
cp -p "$app_plist" "$release_dir/original-info.plist"

python3 - "$app_plist" <<'PY'
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

PY

key_file="$release_dir/app-store-connect.p8"
certificate_file="$release_dir/distribution.p12"
profile_file="$release_dir/app-store.mobileprovision"
printf '%s' "$APP_STORE_CONNECT_KEY_P8_BASE64" | base64 -D > "$key_file"
printf '%s' "$APPLE_DISTRIBUTION_P12_BASE64" | base64 -D > "$certificate_file"
printf '%s' "$APPLE_APP_STORE_PROFILE_BASE64" | base64 -D > "$profile_file"
unset APP_STORE_CONNECT_KEY_P8_BASE64 APPLE_DISTRIBUTION_P12_BASE64 APPLE_APP_STORE_PROFILE_BASE64

keychain_list="$(security list-keychains -d user)"
original_keychains=()
while read -r path; do
  if [[ -n "$path" ]]; then
    path="${path#\"}"
    original_keychains+=("${path%\"}")
  fi
done <<< "$keychain_list"

keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$signing_keychain"
security set-keychain-settings -lut 3600 "$signing_keychain"
security unlock-keychain -p "$keychain_password" "$signing_keychain"
security list-keychains -d user -s "$signing_keychain" ${original_keychains[@]+"${original_keychains[@]}"}
security import "$certificate_file" -f pkcs12 -k "$signing_keychain" \
  -P "$APPLE_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
unset APPLE_DISTRIBUTION_P12_PASSWORD
security set-key-partition-list -s -S apple-tool:,apple: -k "$keychain_password" "$signing_keychain" >/dev/null
unset keychain_password
rm -f -- "$certificate_file"

identity="$(security find-identity -v -p codesigning "$signing_keychain" |
  awk '/"Apple Distribution:/{ print $2 }')"
if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
  printf '%s\n' 'The signing keychain must contain one valid Apple Distribution identity.' >&2
  exit 1
fi

security cms -D -i "$profile_file" -o "$release_dir/profile.plist"
profile_uuid="$(python3 - "$release_dir/profile.plist" "$release_dir/export-options.plist" "$bundle_id" "$identity" <<'PY'
import hashlib
import os
import plistlib
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

profile_file, export_file, bundle_id, identity = sys.argv[1:]
team_id = os.environ["APPLE_TEAM_ID"]
profile = plistlib.loads(Path(profile_file).read_bytes())
entitlements = profile["Entitlements"]
app_id = entitlements.get("application-identifier", "")
app_prefixes = profile.get("ApplicationIdentifierPrefix", [])
if (
    team_id not in profile.get("TeamIdentifier", [])
    or app_id not in {f"{prefix}.{bundle_id}" for prefix in app_prefixes}
    or entitlements.get("get-task-allow") is not False
    or "ProvisionedDevices" in profile
    or profile.get("ProvisionsAllDevices", False)
    or "iOS" not in profile.get("Platform", [])
):
    sys.exit("The profile must be an iOS App Store Connect profile for this team and app.")
if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
    sys.exit("The App Store Connect provisioning profile has expired.")
certificates = profile.get("DeveloperCertificates", [])
if identity.lower() not in {hashlib.sha1(certificate).hexdigest() for certificate in certificates}:
    sys.exit("The App Store Connect provisioning profile does not match the imported certificate.")

profile_uuid = profile["UUID"]
if str(UUID(profile_uuid)) != profile_uuid.lower():
    sys.exit("The provisioning profile does not have a canonical UUID.")
export_options = {
    "destination": "upload",
    "method": "app-store-connect",
    "signingStyle": "manual",
    "signingCertificate": identity,
    "provisioningProfiles": {bundle_id: profile["Name"]},
    "teamID": team_id,
    "manageAppVersionAndBuildNumber": False,
    "testFlightInternalTestingOnly": True,
    "uploadSymbols": True,
}
Path(export_file).write_bytes(plistlib.dumps(export_options))
print(profile_uuid)
PY
)"
profile_name="$(plutil -extract Name raw "$release_dir/profile.plist")"

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

# Xcode supports its UserData store and the original MobileDevice store.
for profile_directory in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  profile_path="$profile_directory/$profile_uuid.mobileprovision"
  if [[ -e "$profile_path" ]]; then
    cmp -s "$profile_path" "$profile_file"
  else
    mkdir -p -m 0755 "$profile_directory"
    install -m 0644 "$profile_file" "$profile_path"
    installed_profiles+=("$profile_path")
  fi
done

xcodebuild -quiet archive -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  "HARBOR_RELEASE_SIGN_STYLE=Manual" \
  "HARBOR_RELEASE_SIGN_TEAM=$APPLE_TEAM_ID" \
  "HARBOR_RELEASE_SIGN_IDENTITY=Apple Distribution" \
  "HARBOR_RELEASE_SIGN_PROFILE=$profile_name"

archive_app="$archive_path/Products/Applications/Runner.app"
archive_plist="$archive_app/Info.plist"
codesign --verify --strict "$archive_app"
security cms -D -i "$archive_app/embedded.mobileprovision" -o "$release_dir/embedded-profile.plist"
if [[ "$(plutil -extract UUID raw "$release_dir/embedded-profile.plist")" != "$profile_uuid" ]]; then
  printf '%s\n' 'Xcode embedded a different provisioning profile than the selected release profile.' >&2
  exit 1
fi
test "$(plutil -extract CFBundleIdentifier raw "$archive_plist")" = "$bundle_id"
test "$(plutil -extract CFBundleDisplayName raw "$archive_plist")" = 心灵港湾
test "$(plutil -extract CFBundleVersion raw "$archive_plist")" = "$build_number"
test "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$archive_plist")" = false
version="$(plutil -extract CFBundleShortVersionString raw "$archive_plist")"

xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$release_dir/export" \
  -exportOptionsPlist "$release_dir/export-options.plist" "${auth[@]}"
printf 'Uploaded iOS %s (%s) to TestFlight for internal testing.\n' "$version" "$build_number"
