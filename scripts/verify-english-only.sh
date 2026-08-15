#!/bin/bash

set -uo pipefail

failed=0

report_failure() {
    echo "English-only check failed: $1" >&2
    failed=1
}

while IFS= read -r localization; do
    case "$localization" in
        Base.lproj|en.lproj) ;;
        *) report_failure "disallowed localization directory: $localization" ;;
    esac
done < <(git ls-files '*.lproj/*' | sed -E 's#^.*/([^/]+\.lproj)/.*$#\1#' | sort -u)

while IFS= read -r tracked_file; do
    filename=${tracked_file##*/}
    lowercase_filename=$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')
    case "$lowercase_filename" in
        readme.*|readme)
            if [[ "$lowercase_filename" != "readme.md" ]]; then
                report_failure "non-English README variant: $tracked_file"
            fi
            ;;
        readme_*.md|readme-*.md)
            report_failure "non-English README variant: $tracked_file"
            ;;
    esac
done < <(git ls-files)

known_foreign_assets=(
    "QuickRecorder/Assets.xcassets/Surprise/ChineseNewYear"
    "img/donate.png"
    "img/preview.png"
    "img/preview_dark.png"
)

for asset in "${known_foreign_assets[@]}"; do
    if git ls-files --error-unmatch "$asset" >/dev/null 2>&1 ||
        git ls-files "$asset" | grep -q .; then
        report_failure "known foreign-language asset: $asset"
    fi
done

cjk_pattern='[\x{2E80}-\x{2EFF}\x{3000}-\x{303F}\x{3040}-\x{30FF}\x{31C0}-\x{31EF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}]'
if cjk_matches=$(git grep -nI -P "$cjk_pattern" -- .); then
    printf '%s\n' "$cjk_matches" >&2
    report_failure "CJK text found in tracked text files"
fi

if [[ $failed -ne 0 ]]; then
    exit 1
fi

echo "English-only check passed"
