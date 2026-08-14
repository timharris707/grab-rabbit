#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <minimum-version> <QuickRecorder.app>" >&2
    exit 2
fi

minimum_version=$1
app_path=${2%/}
info_plist="$app_path/Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
version_pattern='^[0-9]+([.][0-9]+)*$'

if [[ ! -f "$info_plist" ]]; then
    echo "Sparkle version check failed: framework Info.plist not found at $info_plist" >&2
    exit 1
fi

if ! embedded_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null); then
    echo "Sparkle version check failed: CFBundleShortVersionString is missing from $info_plist" >&2
    exit 1
fi

if [[ ! "$minimum_version" =~ $version_pattern ]]; then
    echo "Sparkle version check failed: invalid required version $minimum_version" >&2
    exit 2
fi

if [[ ! "$embedded_version" =~ $version_pattern ]]; then
    echo "Sparkle version check failed: invalid embedded version $embedded_version" >&2
    exit 1
fi

if LC_ALL=C /usr/bin/awk -v embedded="$embedded_version" -v minimum="$minimum_version" '
    function normalize(component) {
        sub(/^0+/, "", component)
        return component == "" ? "0" : component
    }

    BEGIN {
        embedded_count = split(embedded, embedded_parts, ".")
        minimum_count = split(minimum, minimum_parts, ".")
        count = embedded_count > minimum_count ? embedded_count : minimum_count

        for (part_index = 1; part_index <= count; part_index++) {
            embedded_part = normalize(part_index <= embedded_count ? embedded_parts[part_index] : "0")
            minimum_part = normalize(part_index <= minimum_count ? minimum_parts[part_index] : "0")
            if (length(embedded_part) > length(minimum_part)) exit 0
            if (length(embedded_part) < length(minimum_part)) exit 1
            if ("x" embedded_part > "x" minimum_part) exit 0
            if ("x" embedded_part < "x" minimum_part) exit 1
        }

        exit 0
    }
'; then
    echo "Sparkle version check passed: embedded $embedded_version meets required minimum $minimum_version"
else
    echo "Sparkle version check failed: embedded $embedded_version is older than required $minimum_version" >&2
    exit 1
fi
