#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../apps/mobile"
umask 077
release_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xlgw-testflight.XXXXXX")"
app_plist=ios/Runner/Info.plist
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

security cms -D -i "$profile_file" -o "$release_dir/profile.plist"
profile_uuid="$(plutil -extract UUID raw "$release_dir/profile.plist")"
profile_name="$(plutil -extract Name raw "$release_dir/profile.plist")"

python3 - "$app_plist" "$release_dir/export-options.plist" "$profile_name" "$identity" <<'PY'
import base64
import os
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit

info_file, export_file, profile_name, identity = sys.argv[1:]
api_url = os.environ["HARBOR_API_URL"]
url = urlsplit(api_url)
if url.scheme not in {"http", "https"} or not url.hostname or url.username is not None:
    sys.exit("HARBOR_API_URL must be an HTTP or HTTPS URL without credentials.")

# Xcode can log the host separately or emit the Flutter define in base64.
encoded_define = base64.b64encode(f"HARBOR_API_URL={api_url}".encode()).decode()
for value in (url.hostname, encoded_define):
    print(f"::add-mask::{value.replace('%', '%25')}")

if url.scheme == "http":
    app_plist = Path(info_file)
    metadata = plistlib.loads(app_plist.read_bytes())
    ats = metadata.setdefault("NSAppTransportSecurity", {})
    domains = ats.setdefault("NSExceptionDomains", {})
    domains.setdefault(url.hostname, {})["NSExceptionAllowsInsecureHTTPLoads"] = True
    app_plist.write_bytes(plistlib.dumps(metadata, sort_keys=False))

export_options = {
    "destination": "upload",
    "method": "app-store-connect",
    "signingStyle": "manual",
    "signingCertificate": identity,
    "provisioningProfiles": {"dev.oines.xlgw": profile_name},
    "teamID": os.environ["APPLE_TEAM_ID"],
    "manageAppVersionAndBuildNumber": False,
    "testFlightInternalTestingOnly": True,
    "uploadSymbols": True,
}
Path(export_file).write_bytes(plistlib.dumps(export_options))
PY

# Reserve low build numbers for the manually uploaded predecessors.
build_number="$((3 + GITHUB_RUN_NUMBER / 100)).$((GITHUB_RUN_NUMBER % 100)).$GITHUB_RUN_ATTEMPT"
archive_path="$release_dir/Runner.xcarchive"
flutter --suppress-analytics build ios --config-only --release --no-pub --no-codesign --build-number="$build_number" \
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

xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$release_dir/export" \
  -exportOptionsPlist "$release_dir/export-options.plist" -allowProvisioningUpdates \
  -authenticationKeyPath "$key_file" -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"

version="$(plutil -extract CFBundleShortVersionString raw "$archive_path/Products/Applications/Runner.app/Info.plist")"
printf 'Uploaded iOS %s (%s) to TestFlight for internal testing.\n' "$version" "$build_number"
