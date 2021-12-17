#!/bin/bash

function cleanup () {
  echo "Cleaning up any existing Telegraf or Telegraf.app"
  rm -rf Telegraf
  rm -rf Telegraf.app
}

# Acquire the necessary certificates.
# MacCertificate, MacCertificatePassword, AppleSigningAuthorityCertificate are environment variables, to follow convention they should have been all caps.
# shellcheck disable=SC2154
base64 -D -o MacCertificate.p12 <<< "$MacCertificate"
# shellcheck disable=SC2154
sudo security import MacCertificate.p12 -k /Library/Keychains/System.keychain -P "$MacCertificatePassword" -A
# shellcheck disable=SC2154
base64 -D -o AppleSigningAuthorityCertificate.cer <<< "$AppleSigningAuthorityCertificate"
sudo security import AppleSigningAuthorityCertificate.cer -k '/Library/Keychains/System.keychain' -A

# amdFile=$(find . -name "*darwin_amd64.tar*")
armFile=$(find "$HOME/project/dist" -name "*darwin_arm64.tar*")
macFiles=("${armFile}")

for tarFile in "${macFiles[@]}";
do
  cleanup
  echo "Processing $tarFile"

  # Create the .app bundle directory structure
  mkdir -p Telegraf.app/Contents
  mkdir -p Telegraf.app/Contents/MacOS
  mkdir -p Telegraf.app/Contents/Resources

  DeveloperID="Developer ID Application: InfluxData Inc. (M7DN9H35QT)"

  # Sign telegraf binary and the telegraf_entry_mac script
  tar -xzf "$tarFile" --strip-components=2 -C Telegraf.app/Contents/Resources
  codesign -s "$DeveloperID" --timestamp --options=runtime Telegraf.app/Contents/Resources/usr/bin/telegraf
  codesign -v telegraf

  cp ~/project/dist/scripts/telegraf_entry_mac Telegraf/Contents/MacOS
  codesign -s "$DeveloperID" --timestamp --options=runtime Telegraf.app/Contents/MacOS/telegraf_entry_mac
  codesign -v ../scripts/telegraf_entry_mac

  cp ~/project/dist/assets/info.plist Telegraf.app/Contents
  cp  ~/project/dist/assets/icon.icns Telegraf.app/Contents/Resources

  chmod +x Telegraf.app/Contents/MacOS/telegraf_entry_mac

  # Sign the entire .app bundle, and wrap it in a DMG.
  codesign -s "$DeveloperID" --timestamp --options=runtime --deep --force Telegraf.app
  baseName=$(basename "$tarFile" .tar.gz)
  echo "$baseName"
  hdiutil create -size 500m -volname Telegraf -srcfolder Telegraf.app "$baseName".dmg
  codesign -s "$DeveloperID" --timestamp --options=runtime "$baseName".dmg

  # Send the DMG to be notarized.
  # AppleUsername and ApplePassword are environment variables, to follow convention they should have been all caps.
  # shellcheck disable=SC2154
  uuid=$(xcrun altool --notarize-app --primary-bundle-id "com.influxdata.telegraf" --username "$AppleUsername" --password "$ApplePassword" --file "$baseName".dmg | awk '/RequestUUID/ { print $NF; }')
  echo "$uuid"
  if [[ $uuid == "" ]]; then
    echo "Could not upload for notarization."
    exit 1
  fi

  # Wait until the status returns something other than 'in progress'.
  request_status="in progress"
  while [[ "$request_status" == "in progress" ]]; do
    sleep 10
    request_response=$(xcrun altool --notarization-info "$uuid" --username "$AppleUsername" --password "$ApplePassword" 2>&1)
    request_status=$(echo "$request_response" | awk -F ': ' '/Status:/ { print $2; }' )
  done

  if [[ $request_status != "success" ]]; then
    echo "Failed to notarize."
    echo "$request_response"
    cleanup
    exit 1
  fi

  # Attach the notarization to the DMG.
  xcrun stapler staple "$baseName".dmg
  cleanup
  ls

  echo "$tarFile Signed and notarized!"
done