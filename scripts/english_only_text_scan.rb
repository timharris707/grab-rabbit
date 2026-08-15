# frozen_string_literal: true

require "stringio"

module EnglishOnlyTextScan
  # Text inputs are capped at 1 MiB, more than eleven times the current largest
  # tracked text file. Reads stay bounded to 4 KiB and never accumulate a file.
  MAX_TEXT_BYTES = 1024 * 1024
  CHUNK_BYTES = 4 * 1024
  CJK_PATTERN = /[\u{2E80}-\u{2EFF}\u{3000}-\u{303F}\u{3040}-\u{30FF}\u{31C0}-\u{31EF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{AC00}-\u{D7AF}\u{F900}-\u{FAFF}]/

  class ScanError < StandardError; end

  module_function

  def scan_regular(path, display_path, kind)
    metadata = File.lstat(path)
    raise ScanError, "#{kind} is a symbolic link: #{display_path}" if metadata.symlink?
    raise ScanError, "#{kind} is not a regular file: #{display_path}" unless metadata.file?

    File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      opened = file.stat
      unless opened.file? && opened.dev == metadata.dev && opened.ino == metadata.ino
        raise ScanError, "#{kind} changed while opening: #{display_path}"
      end

      return [] if binary?(file, display_path, kind)

      file.rewind
      scan_utf8(file, display_path, kind)
    end
  rescue ScanError
    raise
  rescue StandardError => error
    raise ScanError, "unable to read #{kind} #{display_path}: #{error.message}"
  end

  def scan_link(path, display_path, kind)
    target = File.readlink(path)
    scan_utf8(StringIO.new(target.b), display_path, kind)
  rescue ScanError
    raise
  rescue StandardError => error
    raise ScanError, "unable to read #{kind} #{display_path}: #{error.message}"
  end

  def binary?(file, display_path, kind)
    total_bytes = 0
    while (chunk = file.read(CHUNK_BYTES))
      return true if chunk.include?("\0")

      total_bytes += chunk.bytesize
      if total_bytes > MAX_TEXT_BYTES
        raise ScanError,
              "#{kind} exceeds the #{MAX_TEXT_BYTES}-byte text limit: #{display_path}"
      end
    end
    false
  end

  def scan_utf8(file, display_path, kind)
    pending = "".b
    line_number = 1
    cjk_lines = {}
    total_bytes = 0

    while (chunk = file.read(CHUNK_BYTES))
      total_bytes += chunk.bytesize
      if total_bytes > MAX_TEXT_BYTES
        raise ScanError,
              "#{kind} exceeds the #{MAX_TEXT_BYTES}-byte text limit: #{display_path}"
      end

      buffer = pending + chunk
      prefix_length = valid_utf8_prefix_length(buffer)
      unless prefix_length
        raise ScanError, "#{kind} is not valid UTF-8: #{display_path}"
      end

      line_number = record_cjk_lines(
        buffer.byteslice(0, prefix_length), line_number, cjk_lines
      )
      pending = buffer.byteslice(prefix_length, buffer.bytesize - prefix_length) || "".b
    end

    unless pending.empty?
      text = pending.dup.force_encoding(Encoding::UTF_8)
      raise ScanError, "#{kind} is not valid UTF-8: #{display_path}" unless text.valid_encoding?

      record_cjk_lines(pending, line_number, cjk_lines)
    end

    cjk_lines.keys.sort.map do |matched_line|
      "#{display_path}:#{matched_line}: disallowed CJK text"
    end
  end

  def valid_utf8_prefix_length(buffer)
    maximum_tail = [3, buffer.bytesize].min
    (0..maximum_tail).each do |tail_bytes|
      prefix_length = buffer.bytesize - tail_bytes
      prefix = buffer.byteslice(0, prefix_length).dup.force_encoding(Encoding::UTF_8)
      return prefix_length if prefix.valid_encoding?
    end
    nil
  end

  def record_cjk_lines(bytes, line_number, cjk_lines)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    text.each_line do |line|
      cjk_lines[line_number] = true if line.match?(CJK_PATTERN)
      line_number += 1 if line.end_with?("\n")
    end
    line_number
  end
end
