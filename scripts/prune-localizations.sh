#!/bin/bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [QuickRecorder.app]" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    app_bundle=$1
elif [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
    app_bundle="$TARGET_BUILD_DIR/$WRAPPER_NAME"
else
    echo "Localization pruning failed: app path or Xcode build environment required" >&2
    exit 2
fi

if [[ ! -d "$app_bundle/Contents" ]]; then
    echo "Localization pruning failed: app bundle not found at $app_bundle" >&2
    exit 1
fi

if ! app_parent=$(CDPATH= cd -- "$(dirname -- "$app_bundle")" && pwd -P); then
    echo "Localization pruning failed: unable to resolve app bundle parent" >&2
    exit 1
fi
app_bundle="$app_parent/$(basename -- "$app_bundle")"

# The target names both embedded dependencies as inputs so this final phase runs
# after their copy tasks. Dynamic nested paths require its script sandbox exception.
# Xcode CodeSign and the release lane's leaf-to-host signing both run afterward.
/usr/bin/find "$app_bundle" -depth -type d -name '*.lproj' -print0 |
while IFS= read -r -d '' localization_directory; do
    localization=${localization_directory##*/}
    case "$localization" in
        Base.lproj|en.lproj)
            ;;
        *)
            case "$localization_directory" in
                "$app_bundle"/*) ;;
                *)
                    echo "Localization pruning failed: path escaped app bundle: $localization_directory" >&2
                    exit 1
                    ;;
            esac
            /bin/rm -rf -- "$localization_directory"
            echo "Removed bundled localization: ${localization_directory#"$app_bundle"/}"
            ;;
    esac
done

if [[ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]]; then
    /usr/bin/touch "$SCRIPT_OUTPUT_FILE_0"
fi
