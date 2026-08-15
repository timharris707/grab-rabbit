#!/bin/bash

set -uo pipefail

invocation_directory=$PWD
if ! script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); then
    echo "English-only check failed: unable to resolve the script directory" >&2
    exit 2
fi

if ! repository_root=$(git -C "$script_directory" rev-parse --show-toplevel 2>/dev/null); then
    echo "English-only check failed: the script is not inside a Git worktree" >&2
    exit 2
fi

if ! cd "$repository_root"; then
    echo "English-only check failed: unable to enter repository root $repository_root" >&2
    exit 2
fi

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [QuickRecorder.app]" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    app_bundle=$1
    if [[ "$app_bundle" != /* ]]; then
        app_bundle="$invocation_directory/$app_bundle"
    fi
else
    app_bundle=
fi

source_scan_output=$(ruby -ropen3 -e '
tracked_output, git_status = Open3.capture2e("git", "ls-files", "-z")
unless git_status.success?
  warn "unable to enumerate tracked files: #{tracked_output}"
  exit 2
end

tracked_files = tracked_output.split("\0")
failures = []

localizations = tracked_files.map do |path|
  path[%r{(?:^|/)([^/]+[.]lproj)/}, 1]
end.compact.uniq.sort
localizations.each do |localization|
  next if ["Base.lproj", "en.lproj"].include?(localization)
  failures << "disallowed localization directory: #{localization}"
end

tracked_files.each do |path|
  filename = File.basename(path).downcase
  next if filename == "readme.md"
  if filename == "readme" || filename.start_with?("readme.", "readme_", "readme-")
    failures << "non-English README variant: #{path}"
  end
end

known_foreign_assets = [
  "QuickRecorder/Assets.xcassets/Surprise/ChineseNewYear",
  "img/donate.png",
  "img/preview.png",
  "img/preview_dark.png"
]
known_foreign_assets.each do |asset|
  if tracked_files.any? { |path| path == asset || path.start_with?("#{asset}/") }
    failures << "known foreign-language asset: #{asset}"
  end
end

cjk_pattern = /[\u{2E80}-\u{2EFF}\u{3000}-\u{303F}\u{3040}-\u{30FF}\u{31C0}-\u{31EF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{AC00}-\u{D7AF}\u{F900}-\u{FAFF}]/
tracked_files.each do |path|
  begin
    contents = File.binread(path)
  rescue StandardError => error
    warn "unable to read tracked file #{path}: #{error.message}"
    exit 2
  end

  next if contents.include?("\0")
  text = contents.dup.force_encoding(Encoding::UTF_8)
  unless text.valid_encoding?
    warn "tracked non-binary file is not valid UTF-8: #{path}"
    exit 2
  end

  text.each_line.with_index(1) do |line, line_number|
    if line.match?(cjk_pattern)
      failures << "#{path}:#{line_number}:#{line.chomp}"
    end
  end
end

if failures.empty?
  exit 0
end

failures.each { |failure| warn failure }
exit 3
' 2>&1)
source_scan_status=$?

case $source_scan_status in
    0)
        echo "English-only source check passed"
        ;;
    3)
        printf '%s\n' "$source_scan_output" >&2
        echo "English-only check failed: disallowed source content found" >&2
        exit 1
        ;;
    *)
        printf '%s\n' "$source_scan_output" >&2
        echo "English-only check failed: source scanner error (exit $source_scan_status)" >&2
        exit 2
        ;;
esac

if [[ -z "$app_bundle" ]]; then
    exit 0
fi

if [[ ! -d "$app_bundle/Contents" ]]; then
    echo "English-only check failed: app bundle not found at $app_bundle" >&2
    exit 2
fi

artifact_scan_output=$(ruby -rfind -e '
app_bundle = ARGV.fetch(0)
disallowed = []

begin
  Find.find(app_bundle) do |path|
    next unless File.directory?(path) && File.basename(path).end_with?(".lproj")
    localization = File.basename(path)
    next if ["Base.lproj", "en.lproj"].include?(localization)
    disallowed << path
  end
rescue StandardError => error
  warn "unable to scan app bundle: #{error.message}"
  exit 2
end

if disallowed.empty?
  exit 0
end

disallowed.sort.each { |path| warn "disallowed bundled localization: #{path}" }
exit 3
' "$app_bundle" 2>&1)
artifact_scan_status=$?

case $artifact_scan_status in
    0)
        echo "English-only app bundle check passed: $app_bundle"
        ;;
    3)
        printf '%s\n' "$artifact_scan_output" >&2
        echo "English-only check failed: disallowed app-bundle localization found" >&2
        exit 1
        ;;
    *)
        printf '%s\n' "$artifact_scan_output" >&2
        echo "English-only check failed: app-bundle scanner error (exit $artifact_scan_status)" >&2
        exit 2
        ;;
esac
