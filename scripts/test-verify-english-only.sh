#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
verifier="$script_directory/verify-english-only.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/verify-english-only.XXXXXX")
chunk_bytes=$(ruby -I "$script_directory" -renglish_only_text_scan \
    -e 'print EnglishOnlyTextScan::CHUNK_BYTES')
max_text_bytes=$(ruby -I "$script_directory" -renglish_only_text_scan \
    -e 'print EnglishOnlyTextScan::MAX_TEXT_BYTES')

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

make_source_repo() {
    fixture_name=$1
    fixture_repo="$fixture_root/$fixture_name"
    mkdir -p "$fixture_repo/scripts"
    cp "$verifier" "$script_directory/english_only_text_scan.rb" "$fixture_repo/scripts/"
    git -C "$fixture_repo" init -q
    printf 'English only\n' > "$fixture_repo/README.md"
    printf '%s\n' "$fixture_repo"
}

assert_exit() {
    expected_exit=$1
    fixture_name=$2
    shift 2

    set +e
    "$@" \
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
assert_exit 0 clean "$verifier" "$clean_bundle"

cjk_bundle=$(make_bundle cjk)
printf 'generated \xE4\xB8\xAD\xE6\x96\x87 text\n' \
    > "$cjk_bundle/Contents/Resources/generated.txt"
assert_exit 1 cjk "$verifier" "$cjk_bundle"

localization_bundle=$(make_bundle localization)
mkdir -p "$localization_bundle/Contents/Resources/fr.lproj"
assert_exit 1 localization "$verifier" "$localization_bundle"

known_asset_bundle=$(make_bundle known-asset)
printf '\x89PNG\r\n\x1A\n' > "$known_asset_bundle/Contents/Resources/donate.png"
assert_exit 1 known-asset "$verifier" "$known_asset_bundle"

invalid_utf8_bundle=$(make_bundle invalid-utf8)
printf '\xFF\xFEbroken' > "$invalid_utf8_bundle/Contents/Resources/generated.txt"
assert_exit 2 invalid-utf8 "$verifier" "$invalid_utf8_bundle"

unreadable_bundle=$(make_bundle unreadable)
unreadable_file="$unreadable_bundle/Contents/Resources/generated.txt"
printf 'not readable\n' > "$unreadable_file"
chmod 000 "$unreadable_file"
if [[ ! -r "$unreadable_file" ]]; then
    assert_exit 2 unreadable "$verifier" "$unreadable_bundle"
fi

binary_bundle=$(make_bundle binary)
printf '\0generated \xE4\xB8\xAD\xE6\x96\x87 binary\n' \
    > "$binary_bundle/Contents/Resources/generated.dat"
assert_exit 0 binary "$verifier" "$binary_bundle"

external_bundle=$(make_bundle external-bundle-link)
external_file="$fixture_root/external-bundle-target.txt"
printf 'English only\n' > "$external_file"
ln -s "$external_file" "$external_bundle/Contents/Resources/external-link.txt"
assert_exit 2 external-bundle-link "$verifier" "$external_bundle"

oversize_bundle=$(make_bundle oversize)
ruby -e 'File.open(ARGV[0], "wb") { |file| file.write("a" * ARGV[1].to_i) }' \
    "$oversize_bundle/Contents/Resources/oversize.txt" "$((max_text_bytes + 1))"
assert_exit 2 oversize "$verifier" "$oversize_bundle"

split_utf8_bundle=$(make_bundle split-utf8)
ruby -e 'File.binwrite(ARGV[0], "a" * (ARGV[1].to_i - 1) + "\u00E9\n")' \
    "$split_utf8_bundle/Contents/Resources/split.txt" "$chunk_bytes"
assert_exit 0 split-utf8 "$verifier" "$split_utf8_bundle"

split_cjk_bundle=$(make_bundle split-cjk)
ruby -e 'File.binwrite(ARGV[0], "a" * (ARGV[1].to_i - 1) + "\u4E2D\n")' \
    "$split_cjk_bundle/Contents/Resources/split.txt" "$chunk_bytes"
assert_exit 1 split-cjk "$verifier" "$split_cjk_bundle"

supplementary_bundle=$(make_bundle supplementary-cjk)
ruby -e 'File.binwrite(ARGV[0], "a" * (ARGV[1].to_i - 1) + "\u{20000}\n")' \
    "$supplementary_bundle/Contents/Resources/split.txt" "$chunk_bytes"
assert_exit 1 supplementary-cjk "$verifier" "$supplementary_bundle"

upper_supplementary_bundle=$(make_bundle upper-supplementary-cjk)
ruby -e 'File.binwrite(ARGV[0], "a" * (ARGV[1].to_i - 2) + "\u{3347F}\n")' \
    "$upper_supplementary_bundle/Contents/Resources/split.txt" "$chunk_bytes"
assert_exit 1 upper-supplementary-cjk "$verifier" "$upper_supplementary_bundle"

safe_link_bundle=$(make_bundle internal-safe-link)
ln -s clean.txt "$safe_link_bundle/Contents/Resources/internal-link.txt"
assert_exit 0 internal-safe-link "$verifier" "$safe_link_bundle"

supplementary_character=$(ruby -e 'print "\u{20000}"')
cjk_link_bundle=$(make_bundle internal-cjk-link)
cjk_link_target="target-$supplementary_character.txt"
printf 'English only\n' > "$cjk_link_bundle/Contents/Resources/$cjk_link_target"
ln -s "$cjk_link_target" "$cjk_link_bundle/Contents/Resources/internal-link.txt"
assert_exit 1 internal-cjk-link "$verifier" "$cjk_link_bundle"

external_source="$fixture_root/external-source.txt"
printf 'external \xE4\xB8\xAD\xE6\x96\x87 content\n' > "$external_source"
source_link_repo=$(make_source_repo source-link-no-dereference)
ln -s ../external-source.txt "$source_link_repo/source-link"
git -C "$source_link_repo" add README.md source-link
assert_exit 0 source-link-no-dereference \
    "$source_link_repo/scripts/verify-english-only.sh"

source_link_text_repo=$(make_source_repo source-link-text)
source_link_target=$(printf '../outside-\xE4\xB8\xAD\xE6\x96\x87.txt')
ln -s "$source_link_target" "$source_link_text_repo/source-link"
git -C "$source_link_text_repo" add README.md source-link
assert_exit 1 source-link-text \
    "$source_link_text_repo/scripts/verify-english-only.sh"

source_supplementary_repo=$(make_source_repo source-supplementary-cjk)
ruby -e 'File.binwrite(ARGV[0], "a" * (ARGV[1].to_i - 1) + "\u{20000}\n")' \
    "$source_supplementary_repo/split.txt" "$chunk_bytes"
git -C "$source_supplementary_repo" add README.md split.txt
assert_exit 1 source-supplementary-cjk \
    "$source_supplementary_repo/scripts/verify-english-only.sh"

source_oversize_repo=$(make_source_repo source-oversize)
ruby -e 'File.open(ARGV[0], "wb") { |file| file.write("a" * ARGV[1].to_i) }' \
    "$source_oversize_repo/oversize.txt" "$((max_text_bytes + 1))"
git -C "$source_oversize_repo" add README.md oversize.txt
assert_exit 2 source-oversize \
    "$source_oversize_repo/scripts/verify-english-only.sh"

ruby -I "$script_directory" -renglish_only_text_scan -e '
  boundaries = [
    0x20000, 0x2A6DF, 0x2A700, 0x2EE5F,
    0x2F800, 0x2FA1F, 0x30000, 0x3347F
  ]
  abort "supplementary boundary missing" unless boundaries.all? do |codepoint|
    [codepoint].pack("U").match?(EnglishOnlyTextScan::CJK_PATTERN)
  end
'
echo "supplementary-boundaries=0"

echo "English-only verifier fixture tests passed"
