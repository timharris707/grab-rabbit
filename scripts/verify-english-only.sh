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

source_scan_output=$(ruby -I "$script_directory" -renglish_only_text_scan -ropen3 -e '
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

tracked_files.each do |path|
  begin
    metadata = File.lstat(path)
    matches = if metadata.symlink?
                EnglishOnlyTextScan.scan_link(path, path, "tracked source link")
              else
                EnglishOnlyTextScan.scan_regular(path, path, "tracked file")
              end
    failures.concat(matches)
  rescue StandardError => error
    warn error.message
    exit 2
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

artifact_scan_output=$(ruby -I "$script_directory" -renglish_only_text_scan -rfind -e '
app_bundle = ARGV.fetch(0)
failures = []
known_foreign_asset_names = ["donate.png", "preview.png", "preview_dark.png"]

begin
  if File.lstat(app_bundle).symlink?
    warn "app bundle must not be a symbolic link: #{app_bundle}"
    exit 2
  end
  app_root = File.realpath(app_bundle)
  app_prefix = "#{app_root}#{File::SEPARATOR}"

  Find.find(app_bundle) do |path|
    basename = File.basename(path)
    relative_path = path.delete_prefix("#{app_bundle}/")
    metadata = File.lstat(path)

    if metadata.symlink?
      resolved_path = File.realpath(path)
      unless resolved_path == app_root || resolved_path.start_with?(app_prefix)
        warn "bundled symbolic link escapes app bundle: #{relative_path}"
        exit 2
      end
      if basename == "ChineseNewYear" || known_foreign_asset_names.include?(basename)
        failures << "known foreign-language asset: #{relative_path}"
      end
      failures.concat(
        EnglishOnlyTextScan.scan_link(path, relative_path, "bundled symbolic link")
      )
      next
    end

    if metadata.directory?
      if basename.end_with?(".lproj") && !["Base.lproj", "en.lproj"].include?(basename)
        failures << "disallowed bundled localization: #{relative_path}"
      end
      if basename == "ChineseNewYear"
        failures << "known foreign-language asset: #{relative_path}"
      end
      next
    end

    unless metadata.file?
      warn "unsupported bundled file type: #{relative_path}"
      exit 2
    end
    if known_foreign_asset_names.include?(basename)
      failures << "known foreign-language asset: #{relative_path}"
      next
    end

    begin
      failures.concat(
        EnglishOnlyTextScan.scan_regular(path, relative_path, "bundled file")
      )
    rescue EnglishOnlyTextScan::ScanError => error
      warn error.message
      exit 2
    end
  end
rescue StandardError => error
  warn "unable to scan app bundle: #{error.message}"
  exit 2
end

if failures.empty?
  exit 0
end

failures.sort.each { |failure| warn failure }
exit 3
' "$app_bundle" 2>&1)
artifact_scan_status=$?

case $artifact_scan_status in
    0)
        echo "English-only app bundle check passed: $app_bundle"
        ;;
    3)
        printf '%s\n' "$artifact_scan_output" >&2
        echo "English-only check failed: disallowed app-bundle content found" >&2
        exit 1
        ;;
    *)
        printf '%s\n' "$artifact_scan_output" >&2
        echo "English-only check failed: app-bundle scanner error (exit $artifact_scan_status)" >&2
        exit 2
        ;;
esac
