#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
scratch_dir="$(mktemp -d)"
package_dir="$scratch_dir/status-item"
artifact_hashes="$script_dir/artifact-hashes.sha256"

trap 'find "$scratch_dir" -type f -delete; find "$scratch_dir" -depth -type d -empty -delete' EXIT

command -v perl >/dev/null
test "$(wc -l < "$artifact_hashes" | tr -d ' ')" -eq 8
for artifact in \
  master/grab-rabbit-status-template-1024.png \
  master/grab-rabbit-status-template.pdf \
  exports/grab-rabbit-status-16pt.png \
  exports/grab-rabbit-status-18pt.png \
  exports/grab-rabbit-status-22pt.png \
  exports/grab-rabbit-status-16pt@2x.png \
  exports/grab-rabbit-status-18pt@2x.png \
  exports/grab-rabbit-status-22pt@2x.png; do
  grep -Fq "  $artifact" "$artifact_hashes"
done

cp -R "$script_dir" "$package_dir"
perl -0pi -e 's/M350 438/M351 438/' \
  "$package_dir/source/grab-rabbit-status-template.svg"
grep -Fq 'M351 438' "$package_dir/source/grab-rabbit-status-template.svg"

set +e
derivation_output=$("$package_dir/derive-status-icon.sh" 2>&1)
derivation_status=$?
set -e

if [[ $derivation_status -eq 0 ]]; then
  echo 'Hash validation test failed: changed source produced undocumented artifacts successfully' >&2
  exit 1
fi

if ! grep -Fq 'FAILED' <<<"$derivation_output"; then
  echo 'Hash validation test failed: derivation did not report an artifact hash mismatch' >&2
  exit 1
fi

echo 'Artifact hash mismatch was rejected'
