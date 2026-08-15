#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
scratch_dir="$(mktemp -d)"

trap 'find "$scratch_dir" -type f -delete; find "$scratch_dir" -depth -type d -empty -delete' EXIT

command -v perl >/dev/null

copy_package() {
  local name="$1"
  local package_dir="$scratch_dir/$name"
  cp -R "$script_dir" "$package_dir"
  printf '%s\n' "$package_dir"
}

expect_failure() {
  local name="$1"
  local package_dir="$2"
  local expected_output="$3"
  local derivation_output

  if derivation_output=$("$package_dir/derive-status-icon.sh" 2>&1); then
    echo "Hash validation test failed: $name derivation succeeded" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_output" <<<"$derivation_output"; then
    echo "Hash validation test failed: $name did not report $expected_output" >&2
    exit 1
  fi
  echo "$name was rejected"
}

deleted_package=$(copy_package deleted-entry)
perl -ni -e 'print unless /exports\/grab-rabbit-status-22pt\@2x[.]png$/' \
  "$deleted_package/artifact-hashes.sha256"
expect_failure 'Deleted manifest entry' "$deleted_package" 'Artifact hash manifest'

duplicate_package=$(copy_package duplicate-entry)
duplicate_line=$(sed -n '1p' "$duplicate_package/artifact-hashes.sha256")
printf '%s\n' "$duplicate_line" >> "$duplicate_package/artifact-hashes.sha256"
expect_failure 'Duplicate manifest entry' "$duplicate_package" 'Artifact hash manifest'

extra_package=$(copy_package extra-entry)
printf '%s  %s\n' \
  '0000000000000000000000000000000000000000000000000000000000000000' \
  'exports/undocumented.png' >> "$extra_package/artifact-hashes.sha256"
expect_failure 'Extra manifest entry' "$extra_package" 'Artifact hash manifest'

changed_source_package=$(copy_package changed-source)
perl -0pi -e 's/M350 438/M351 438/' \
  "$changed_source_package/source/grab-rabbit-status-template.svg"
grep -Fq 'M351 438' "$changed_source_package/source/grab-rabbit-status-template.svg"
expect_failure 'Changed source' "$changed_source_package" 'FAILED'

clean_package=$(copy_package clean)
clean_output=$("$clean_package/derive-status-icon.sh" 2>&1)
test "$(grep -c ': OK$' <<<"$clean_output")" -eq 8
echo 'Clean derivation validated 8/8 artifact hashes'
