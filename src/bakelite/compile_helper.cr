require "compress/deflate"
require "compress/gzip"
require "compress/zlib"
require "digest/crc32"
require "base64"
require "json"
require "yaml"
require "path"
require "./glob"
require "./transform/builtins"
require "./transform/runner"

# Compile-time helper executed via `run("./compile_helper.cr", ...)` during macro expansion.
# Handles directory globbing, file exclusions, compile-time transformations,
# declarative manifest parsing, and single-pass batch chunking/compression for embedded assets.

module CompileHelper
  def self.compress_chunk(chunk_raw : Bytes, comp_sym : String) : Bytes
    case comp_sym.downcase.lchop(':')
    when "gzip"
      mem = IO::Memory.new
      Compress::Gzip::Writer.open(mem) { |g| g.write(chunk_raw) }
      mem.to_slice
    when "zlib"
      mem = IO::Memory.new
      Compress::Zlib::Writer.open(mem) { |z| z.write(chunk_raw) }
      mem.to_slice
    when "none", "raw"
      chunk_raw
    else # deflate
      mem = IO::Memory.new
      Compress::Deflate::Writer.open(mem) { |d| d.write(chunk_raw) }
      mem.to_slice
    end
  end

  def self.comp_enum_str(comp_sym : String) : String
    case comp_sym.downcase.lchop(':')
    when "gzip"        then "::Bakelite::CompressionType::Gzip"
    when "zlib"        then "::Bakelite::CompressionType::Zlib"
    when "none", "raw" then "::Bakelite::CompressionType::None"
    else                    "::Bakelite::CompressionType::Deflate"
    end
  end

  # Scans base_dir for files matching patterns and not matching excludes
  def self.find_files(base_dir : String, patterns : Array(String), excludes : Array(String)) : Array(String)
    norm_base = base_dir.tr("\\", "/").rstrip('/')
    candidates = Set(String).new

    # Check exact file matches if present in patterns
    patterns.each do |pat|
      next if pat.starts_with?('!') || pat.includes?('*') || pat.includes?('?')
      exact_path = norm_base.empty? || norm_base == "." ? pat : "#{norm_base}/#{pat}"
      if File.file?(exact_path)
        candidates << pat.tr("\\", "/").strip('/')
      end
    end

    # Scan only specific pattern globs
    patterns.each do |pat|
      next if pat.starts_with?('!')
      clean_pat = pat.tr("\\", "/").strip('/')

      if clean_pat.includes?('*') || clean_pat.includes?('?')
        glob_target = norm_base.empty? || norm_base == "." ? clean_pat : "#{norm_base}/#{clean_pat}"
        globs_to_run = [glob_target]
        if clean_pat.ends_with?("**/*")
          globs_to_run << glob_target.sub(/\*\*\/\*$/, "**/.*")
        end

        Dir.glob(globs_to_run).each do |match|
          next unless File.file?(match)
          rel = if norm_base.empty? || norm_base == "."
                  match.tr("\\", "/").strip('/')
                else
                  Path.new(match).relative_to(Path.new(norm_base)).to_s.tr("\\", "/").strip('/')
                end
          candidates << rel
        end
      end
    end

    candidates.reject! { |c| c.starts_with?(".git/") || c == ".git" }

    # Filter with Bakelite::Glob.match?
    result = [] of String
    candidates.to_a.sort.each do |rel|
      if Bakelite::Glob.match?(rel, patterns, excludes)
        result << rel
      end
    end
    result
  end

  # Emits Crystal code to construct and add an item to the specified volume
  def self.emit_file(
    io : IO,
    full_disk_path : String,
    v_path : String,
    vol_name : String,
    mode : String,
    chunk_size : UInt32,
    comp_sym : String,
    transform_spec : String?,
    auto_threshold : Int64? = nil,
  )
    unless File.exists?(full_disk_path)
      STDERR.puts "[Bakelite Warning] File not found: #{full_disk_path}"
      return
    end

    raw_bytes = File.read(full_disk_path)

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
    total_size = final_bytes.size.to_i64
    total_crc32 = Digest::CRC32.checksum(final_bytes)

    # Determine whether to bake or store
    effective_mode = mode
    if auto_threshold && (mode == "auto" || mode.empty?)
      effective_mode = total_size < auto_threshold ? "bake" : "store"
    elsif mode == "auto"
      effective_mode = total_size < 16384 ? "bake" : "store"
    end

    # Emit compile warning if baked file > 10MB
    if effective_mode == "bake" && total_size > 10_485_760
      mb_str = sprintf("%.2f MB", total_size / (1024.0 * 1024.0))
      STDERR.puts "\e[33m[Bakelite Warning]\e[0m File '#{full_disk_path}' is #{mb_str}. Inlining large files via 'bake' bloats executable binary. Consider using 'store' for chunked streaming storage."
    end

    if effective_mode == "bake"
      b64 = Base64.strict_encode(final_bytes)
      io.puts "(fs.volume?(#{vol_name.inspect}) || fs.root_volume).add("
      io.puts "  ::Bakelite::BakedItem.new("
      io.puts "    path: #{v_path.inspect},"
      io.puts "    volume_name: #{vol_name.inspect},"
      io.puts "    data: ::Base64.decode(#{b64.inspect}),"
      io.puts "    mime_type: ::Bakelite::MIME.from_path(#{v_path.inspect}),"
      io.puts "    crc32: #{total_crc32}_u32"
      io.puts "  )"
      io.puts ")"
    else
      # Store mode: chunk and compress
      chunks_code = IO::Memory.new
      chunks_code << "["
      running_offset = 0_i64
      pos = 0
      first = true

      while pos < total_size
        slice_len = Math.min(chunk_size.to_i32, (total_size - pos).to_i32)
        chunk_raw = final_bytes[pos, slice_len]
        chunk_crc = Digest::CRC32.checksum(chunk_raw)

        comp_bytes = compress_chunk(chunk_raw, comp_sym)
        b64 = Base64.strict_encode(comp_bytes)

        chunks_code << ", " unless first
        first = false

        chunks_code << "::Bakelite::Chunk.new("
        chunks_code << "offset: #{running_offset}_i64, "
        chunks_code << "compressed_size: #{comp_bytes.size}_u32, "
        chunks_code << "uncompressed_size: #{slice_len}_u32, "
        chunks_code << "crc32: #{chunk_crc}_u32, "
        chunks_code << "data: ::Base64.decode(#{b64.inspect})"
        chunks_code << ")"

        running_offset += comp_bytes.size
        pos += slice_len
      end
      chunks_code << "]"
      total_compressed = running_offset
      comp_enum = comp_enum_str(comp_sym)

      io.puts "(fs.volume?(#{vol_name.inspect}) || fs.root_volume).add("
      io.puts "  ::Bakelite::StoredItem.new("
      io.puts "    path: #{v_path.inspect},"
      io.puts "    volume_name: #{vol_name.inspect},"
      io.puts "    size: #{total_size}_i64,"
      io.puts "    compressed_size: #{total_compressed}_i64,"
      io.puts "    chunks: #{chunks_code.to_s},"
      io.puts "    compression: #{comp_enum},"
      io.puts "    mime_type: ::Bakelite::MIME.from_path(#{v_path.inspect}),"
      io.puts "    crc32: #{total_crc32}_u32"
      io.puts "  )"
      io.puts ")"
    end
  end

  def self.process_manifest(manifest_path : String, base_dir : String = ".")
    unless File.exists?(manifest_path)
      STDERR.puts "[Bakelite Error] Manifest file not found: #{manifest_path}"
      exit 1
    end

    manifest_content = File.read(manifest_path)
    yaml = YAML.parse(manifest_content)

    volumes_node = yaml["volumes"]?
    unless volumes_node && volumes_node.as_h?
      STDERR.puts "[Bakelite Error] Manifest must contain a top-level 'volumes:' mapping."
      exit 1
    end

    volumes_hash = volumes_node.as_h

    volumes_hash.each do |vol_key, vol_config|
      vol_name = vol_key.as_s.lchop(':')
      vol_h = vol_config.as_h? || Hash(YAML::Any, YAML::Any).new

      mount = vol_h["mount"]?.try(&.as_s?) || ""
      priority = vol_h["priority"]?.try(&.as_i?) || 0
      chunk_size = (vol_h["default_chunk_size"]? || vol_h["chunk_size"]?).try(&.as_i64?.try(&.to_u32)) || 65536_u32
      comp_sym = (vol_h["default_compression"]? || vol_h["compression"]?).try(&.as_s?) || "deflate"
      auto_thresh = vol_h["auto_threshold"]?.try(&.as_i64?)
      mode = vol_h["mode"]?.try(&.as_s?) || (auto_thresh ? "auto" : "store")
      strip_prefix = vol_h["strip_prefix"]?.try(&.as_s?)
      transform = vol_h["transform"]?.try(&.as_s?)

      files_list = [] of String
      if f_node = vol_h["files"]?
        if f_arr = f_node.as_a?
          f_arr.each { |item| files_list << item.as_s }
        elsif f_str = f_node.as_s?
          files_list << f_str
        end
      end

      exclude_list = [] of String
      if e_node = vol_h["exclude"]?
        if e_arr = e_node.as_a?
          e_arr.each { |item| exclude_list << item.as_s }
        elsif e_str = e_node.as_s?
          exclude_list << e_str
        end
      end

      # Mount/register the volume
      comp_enum = comp_enum_str(comp_sym)
      if vol_name == "root"
        puts "fs.root_volume.mount_point = #{mount.inspect} unless #{mount.inspect}.empty?"
        puts "fs.root_volume.priority = #{priority}"
      else
        puts "fs.volume?(#{vol_name.inspect}) || fs.mount(::Bakelite::Volume.new(#{vol_name.inspect}, mount_point: #{mount.inspect}, priority: #{priority}, default_chunk_size: #{chunk_size}_u32, default_compression: #{comp_enum}))"
      end

      # Find matching files on disk
      matched_files = find_files(base_dir, files_list, exclude_list)

      matched_files.each do |rel_file|
        full_disk_path = File.join(base_dir, rel_file)

        # Compute v_path
        v_path = if strip_prefix
                   if !strip_prefix.empty? && rel_file.starts_with?("#{strip_prefix}/")
                     rel_file[(strip_prefix.size + 1)..-1]
                   elsif rel_file == strip_prefix
                     ""
                   else
                     rel_file
                   end
                 elsif !mount.empty? && rel_file.starts_with?("#{mount}/")
                   rel_file[(mount.size + 1)..-1]
                 else
                   rel_file
                 end

        emit_file(
          io: STDOUT,
          full_disk_path: full_disk_path,
          v_path: v_path,
          vol_name: vol_name,
          mode: mode,
          chunk_size: chunk_size,
          comp_sym: comp_sym,
          transform_spec: transform,
          auto_threshold: auto_thresh
        )
      end
    end
  end

  def self.process_folder_batch(
    mode : String,
    dir : String,
    prefix : String,
    volume_name : String,
    chunk_size : UInt32,
    comp_sym : String,
    transform_spec : String?,
    exclude_csv : String,
    threshold : Int64? = nil,
  )
    volume_clean = volume_name.lchop(':')
    excludes = exclude_csv.split(',').map(&.strip).reject(&.empty?)
    patterns = ["**/*"]

    matched_files = find_files(dir, patterns, excludes)

    # Ensure volume exists
    comp_enum = comp_enum_str(comp_sym)
    if volume_clean != "root"
      puts "fs.volume?(#{volume_clean.inspect}) || fs.mount(::Bakelite::Volume.new(#{volume_clean.inspect}, mount_point: \"\", priority: 0, default_chunk_size: #{chunk_size}_u32, default_compression: #{comp_enum}))"
    end

    matched_files.each do |rel_file|
      full_disk_path = File.join(dir, rel_file)
      v_path = prefix.empty? ? rel_file : "#{prefix.strip('/')}/#{rel_file}"

      emit_file(
        io: STDOUT,
        full_disk_path: full_disk_path,
        v_path: v_path,
        vol_name: volume_clean,
        mode: mode,
        chunk_size: chunk_size,
        comp_sym: comp_sym,
        transform_spec: transform_spec,
        auto_threshold: threshold
      )
    end
  end
end

mode = ARGV[0]? || "help"

case mode
when "batch_process"
  submode = ARGV[1]? || "help"
  case submode
  when "manifest"
    manifest_path = ARGV[2]? || "manifest.yml"
    base_dir = ARGV[3]? || "."
    CompileHelper.process_manifest(manifest_path, base_dir)
  when "folder"
    mode_type = ARGV[2]? || "bake"
    dir = ARGV[3]? || "."
    prefix = ARGV[4]? || ""
    volume = ARGV[5]? || "root"
    chunk_size = (ARGV[6]? || "65536").to_u32
    compress = ARGV[7]? || "deflate"
    transform = ARGV[8]?
    exclude = ARGV[9]? || ""
    threshold = ARGV[10]?.try(&.to_i64?)
    CompileHelper.process_folder_batch(mode_type, dir, prefix, volume, chunk_size, compress, transform, exclude, threshold)
  else
    if submode.ends_with?(".yml") || submode.ends_with?(".yaml")
      base_dir = ARGV[2]? || "."
      CompileHelper.process_manifest(submode, base_dir)
    else
      STDERR.puts "Unknown batch_process submode: #{submode}"
      exit 1
    end
  end
when "manifest"
  manifest_path = ARGV[1]? || "manifest.yml"
  base_dir = ARGV[2]? || "."
  CompileHelper.process_manifest(manifest_path, base_dir)
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

    # Check exclusions with Glob
    next unless Bakelite::Glob.match?(rel, ["**/*"], excludes)

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
    if total_size > 10_485_760
      mb_str = sprintf("%.2f MB", total_size / (1024.0 * 1024.0))
      STDERR.puts "\e[33m[Bakelite Warning]\e[0m File '#{file_path}' is #{mb_str}. Inlining large files via 'bake' bloats executable binary. Consider using 'store' for chunked streaming storage."
    end

    puts "META|bake|#{total_size}|#{total_size}|#{total_crc32}|none|#{chunk_size}"
    puts "DATA|#{Base64.strict_encode(final_bytes)}"
    puts "END"
  else
    chunks = [] of Hash(String, String | UInt32 | Int64)
    running_offset = 0_i64
    pos = 0

    while pos < total_size
      slice_len = Math.min(chunk_size.to_i32, total_size - pos)
      chunk_raw = final_bytes[pos, slice_len]
      chunk_crc = Digest::CRC32.checksum(chunk_raw)

      comp_bytes = CompileHelper.compress_chunk(chunk_raw, compress_sym)

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
