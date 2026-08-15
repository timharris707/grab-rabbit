#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
verifier="$script_directory/verify-english-only.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/verify-english-only.XXXXXX")

cleanup() {
    chmod -R u+rwX "$fixture_root"
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT

make_bundle() {
    fixture_name=$1
    fixture_bundle="$fixture_root/$fixture_name/QuickRecorder.app"
    mkdir -p "$fixture_bundle/Contents/Resources"
    printf 'English only\n' > "$fixture_bundle/Contents/Resources/clean.txt"
    printf '%s\n' "$fixture_bundle"
}

assert_exit() {
    expected_exit=$1
    fixture_name=$2
    fixture_bundle=$3

    set +e
    "$verifier" "$fixture_bundle" \
        > "$fixture_root/$fixture_name.stdout" \
        2> "$fixture_root/$fixture_name.stderr"
    actual_exit=$?
    set -e

    if [[ $actual_exit -ne $expected_exit ]]; then
        echo "$fixture_name: expected exit $expected_exit, got $actual_exit" >&2
        sed -n '1,120p' "$fixture_root/$fixture_name.stderr" >&2
        exit 1
    fi

    printf '%s=%s\n' "$fixture_name" "$actual_exit"
}

clean_bundle=$(make_bundle clean)
assert_exit 0 clean "$clean_bundle"

cjk_bundle=$(make_bundle cjk)
printf 'generated \xE4\xB8\xAD\xE6\x96\x87 text\n' \
    > "$cjk_bundle/Contents/Resources/generated.txt"
assert_exit 1 cjk "$cjk_bundle"

localization_bundle=$(make_bundle localization)
mkdir -p "$localization_bundle/Contents/Resources/fr.lproj"
assert_exit 1 localization "$localization_bundle"

known_asset_bundle=$(make_bundle known-asset)
printf '\x89PNG\r\n\x1A\n' > "$known_asset_bundle/Contents/Resources/donate.png"
assert_exit 1 known-asset "$known_asset_bundle"

invalid_utf8_bundle=$(make_bundle invalid-utf8)
printf '\xFF\xFEbroken' > "$invalid_utf8_bundle/Contents/Resources/generated.txt"
assert_exit 2 invalid-utf8 "$invalid_utf8_bundle"

unreadable_bundle=$(make_bundle unreadable)
unreadable_file="$unreadable_bundle/Contents/Resources/generated.txt"
printf 'not readable\n' > "$unreadable_file"
chmod 000 "$unreadable_file"
if [[ ! -r "$unreadable_file" ]]; then
    assert_exit 2 unreadable "$unreadable_bundle"
fi

binary_bundle=$(make_bundle binary)
printf '\0generated \xE4\xB8\xAD\xE6\x96\x87 binary\n' \
    > "$binary_bundle/Contents/Resources/generated.dat"
assert_exit 0 binary "$binary_bundle"

echo "English-only verifier fixture tests passed"
