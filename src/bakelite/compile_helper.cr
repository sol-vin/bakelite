require "compress/deflate"
require "compress/gzip"
require "compress/zlib"
require "digest/crc32"
require "base64"
require "json"
require "path"
require "./transform/builtins"
require "./transform/runner"

# Compile-time helper executed via `run("./compile_helper.cr", ...)` during macro expansion.
# Handles directory globbing, file exclusions, compile-time transformations,
# and chunking/compression for large embedded assets.

mode = ARGV[0]? || "help"

case mode
when "glob_folder"
  # ARGV[1] = dir_path, ARGV[2] = comma-separated exclude patterns
  dir_path = ARGV[1]? || "."
  excludes = (ARGV[2]? || "").split(',').map(&.strip).reject(&.empty?)

  unless Dir.exists?(dir_path)
    STDERR.puts "Directory not found: #{dir_path}"
    exit 1
  end

  pattern = File.join(dir_path, "**/*").tr("\\", "/")
  Dir.glob(pattern).sort.each do |match|
    next unless File.file?(match)
    rel = Path.new(match).relative_to(Path.new(dir_path)).to_s.tr("\\", "/")

    # Check exclusions
    excluded = excludes.any? do |ex|
      File.match?(ex.tr("\\", "/"), rel) || rel.includes?(ex)
    end
    next if excluded

    puts rel
  end
when "process_file"
  # ARGV: mode, file_path, storage_mode (bake/store), chunk_size, compress, transform
  file_path = ARGV[1]
  storage_mode = ARGV[2]? || "bake"
  chunk_size = (ARGV[3]? || "65536").to_u32
  compress_sym = (ARGV[4]? || "deflate")
  transform_spec = ARGV[5]?

  unless File.exists?(file_path)
    STDERR.puts "File not found: #{file_path}"
    exit 1
  end

  raw_bytes = File.read(file_path)

  # Apply transform if specified
  transformed_str = if transform_spec && !transform_spec.empty? && transform_spec != "none"
                      if transform_spec.starts_with?(':')
                        Bakelite::Transform::Builtins.apply(transform_spec, raw_bytes)
                      else
                        Bakelite::Transform::Runner.run(raw_bytes, transform_spec, cache_enabled: true)
                      end
                    else
                      raw_bytes
                    end

  final_bytes = transformed_str.to_slice
  total_size = final_bytes.size
  total_crc32 = Digest::CRC32.checksum(final_bytes)

  if storage_mode == "bake"
    # Emit compile-time warning if baked file exceeds 10MB threshold
    if total_size > 10_485_760
      mb_str = sprintf("%.2f MB", total_size / (1024.0 * 1024.0))
      STDERR.puts "\e[33m[Bakelite Warning]\e[0m File '#{file_path}' is #{mb_str}. Inlining large files via 'bake' bloats executable binary. Consider using 'store' for chunked streaming storage."
    end

    puts "META|bake|#{total_size}|#{total_size}|#{total_crc32}|none|#{chunk_size}"
    puts "DATA|#{Base64.strict_encode(final_bytes)}"
    puts "END"
  else
    # Store mode: chunk and compress
    chunks = [] of Hash(String, String | UInt32 | Int64)
    running_offset = 0_i64
    pos = 0

    while pos < total_size
      slice_len = Math.min(chunk_size.to_i32, total_size - pos)
      chunk_raw = final_bytes[pos, slice_len]
      chunk_crc = Digest::CRC32.checksum(chunk_raw)

      # Compress chunk
      comp_type = case compress_sym
                  when "gzip" then :gzip
                  when "zlib" then :zlib
                  when "none" then :none
                  else             :deflate
                  end

      comp_bytes = case comp_type
                   when :deflate
                     mem = IO::Memory.new
                     Compress::Deflate::Writer.open(mem) { |d| d.write(chunk_raw) }
                     mem.to_slice
                   when :zlib
                     mem = IO::Memory.new
                     Compress::Zlib::Writer.open(mem) { |z| z.write(chunk_raw) }
                     mem.to_slice
                   when :gzip
                     mem = IO::Memory.new
                     Compress::Gzip::Writer.open(mem) { |g| g.write(chunk_raw) }
                     mem.to_slice
                   else
                     chunk_raw
                   end

      chunks << {
        "offset"            => running_offset,
        "compressed_size"   => comp_bytes.size.to_u32,
        "uncompressed_size" => slice_len.to_u32,
        "crc32"             => chunk_crc,
        "data_b64"          => Base64.strict_encode(comp_bytes),
      }

      running_offset += comp_bytes.size
      pos += slice_len
    end

    total_compressed = chunks.sum { |c| c["compressed_size"].as(UInt32).to_i64 }

    puts "META|store|#{total_size}|#{total_compressed}|#{total_crc32}|#{compress_sym}|#{chunk_size}"
    chunks.each do |c|
      puts "CHUNK|#{c["offset"]}|#{c["compressed_size"]}|#{c["uncompressed_size"]}|#{c["crc32"]}|#{c["data_b64"]}"
    end
    puts "END"
  end
else
  STDERR.puts "Unknown mode: #{mode}"
  exit 1
end
