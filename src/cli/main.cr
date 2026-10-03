require "option_parser"
require "opal"
require "carbon"
require "jasper"
require "../bakelite"

module Bakelite
  module CLI
    def self.run(args = ARGV)
      command = args.first? || "help"

      case command
      when "pack"
        run_pack(args[1..-1])
      when "list", "ls"
        run_list(args[1..-1])
      when "inspect"
        run_inspect(args[1..-1])
      when "verify"
        run_verify(args[1..-1])
      when "extract"
        run_extract(args[1..-1])
      when "docs"
        run_docs(args[1..-1])
      when "version", "-v", "--version"
        print_version
      when "help", "-h", "--help"
        print_help
      else
        STDERR.puts "\e[31mError:\e[0m Unknown command '#{command}'"
        print_help
        exit 1
      end
    end

    private def self.print_version
      puts "\e[1;36mBakelite\e[0m v#{Bakelite::VERSION} (powered by \e[33mCarbon\e[0m, \e[32mOpal\e[0m, and \e[35mJasper\e[0m)"
    end

    private def self.print_help
      puts <<-HELP
\e[1;36m=== Bakelite: General-Purpose Baked & Virtual Filesystem for Crystal ===\e[0m
\e[90mVersion: #{Bakelite::VERSION}\e[0m

\e[1mUsage:\e[0m
  bakelite <command> [arguments] [options]

\e[1mCommands:\e[0m
  \e[32mpack\e[0m <target> <source_dir>   Pack/append files into an executable or .bkl container
  \e[32mlist\e[0m <target>                 List all files, volumes, and compression stats
  \e[32minspect\e[0m <target>               Inspect volume headers, trailer, and metadata
  \e[32mverify\e[0m <target>               Verify CRC32 integrity of all chunks and files
  \e[32mextract\e[0m <target> <dest_dir>   Extract container or appended volume to disk
  \e[32mdocs\e[0m [options]                 Generate HTML/Markdown documentation using Jasper
  \e[32mversion\e[0m                        Show Bakelite version info
  \e[32mhelp\e[0m                           Show this help message

\e[1mPack Options:\e[0m
  --volume <name>            Volume name (default: root)
  --mount <prefix>           Mount prefix path (default: "")
  --priority <int>           Volume union priority rank (default: 0)
  --chunk-size <bytes>       Chunk size in bytes or suffix (64k, 256k, 1m; default: 64k)
  --compress <type>          Compression: deflate, gzip, zlib, none (default: deflate)
  --exclude <patterns>       Comma-separated glob exclusion patterns
  --no-append                Overwrite target file instead of appending

\e[1mExamples:\e[0m
  bakelite pack game.exe assets/audio/ --volume audio --mount audio/ --chunk-size 128k
  bakelite inspect game.exe
  bakelite list game.exe
  bakelite verify game.exe
  bakelite extract game.exe dist/extracted_assets/
HELP
    end

    private def self.run_pack(args : Array(String))
      target : String? = nil
      source_dir : String? = nil
      volume_name = "root"
      mount_point = ""
      priority = 0
      chunk_size = 65536_u32
      compress_type = CompressionType::Deflate
      excludes = [] of String
      append = true

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bakelite pack <target-exe-or-bkl> <source-dir> [options]"
        opts.on("--volume NAME", "Name of the volume") { |v| volume_name = v }
        opts.on("--mount PREFIX", "Mount point prefix in virtual filesystem") { |m| mount_point = m }
        opts.on("--priority RANK", "Volume union priority (higher shadows lower)") { |p| priority = p.to_i }
        opts.on("--chunk-size BYTES", "Chunk size in bytes (e.g. 64k, 256k, 1m)") do |cs|
          chunk_size = parse_size(cs)
        end
        opts.on("--compress TYPE", "Compression algorithm (deflate, gzip, zlib, none)") do |c|
          compress_type = CompressionType.parse(c)
        end
        opts.on("--exclude PATTERNS", "Comma-separated exclusion patterns") do |ex|
          excludes = ex.split(',').map(&.strip).reject(&.empty?)
        end
        opts.on("--no-append", "Do not append; overwrite file") { append = false }
        opts.on("-h", "--help", "Show help") do
          puts opts
          exit 0
        end
      end

      parser.parse(args)
      if args.size < 2
        STDERR.puts "\e[31mError:\e[0m Missing target or source directory."
        puts parser
        exit 1
      end

      target = args[0]
      source_dir = args[1]

      puts "\e[1;36m=== Bakelite: Packing Volume ===\e[0m"
      puts "  Target:       \e[33m#{target}\e[0m"
      puts "  Source:       \e[33m#{source_dir}\e[0m"
      puts "  Volume:       \e[35m:#{volume_name}\e[0m (mount: \"#{mount_point}\", priority: #{priority})"
      puts "  Chunk Size:   #{chunk_size} bytes"
      puts "  Compression:  \e[32m#{compress_type}\e[0m"

      writer = Container::Writer.new(target)
      writer.pack_directory(
        source_dir: source_dir,
        volume_name: volume_name,
        mount_point: mount_point,
        priority: priority,
        chunk_size: chunk_size,
        compression: compress_type,
        exclude: excludes
      )

      payload_size = writer.write(append: append)
      puts "\e[32m✓ Packed successfully!\e[0m Volume payload written: \e[1m#{format_size(payload_size)}\e[0m"
    end

    private def self.run_list(args : Array(String))
      target = args.first?
      unless target && File.exists?(target)
        STDERR.puts "\e[31mError:\e[0m Missing or invalid target file."
        exit 1
      end

      reader = Container::Reader.new(target)
      volumes = reader.read

      if volumes.empty?
        puts "\e[33mNo Bakelite volumes found in #{target}.\e[0m"
        return
      end

      rows = [] of Array(String)
      total_uncompressed = 0_i64
      total_compressed = 0_i64

      volumes.each do |vol|
        vol.each_file do |item|
          total_uncompressed += item.size
          total_compressed += item.compressed_size

          ratio = if item.size > 0
                    percent = (1.0 - (item.compressed_size.to_f / item.size.to_f)) * 100.0
                    sprintf("%.1f%%", Math.max(0.0, percent))
                  else
                    "0.0%"
                  end

          rows << [
            item.path,
            ":#{vol.name}",
            item.storage_mode.to_s,
            format_size(item.size),
            format_size(item.compressed_size),
            ratio,
            item.crc32_hex,
          ]
        end
      end

      table = Opal::UI::Table.new(
        headers: ["Path", "Volume", "Mode", "Size", "Compressed", "Ratio", "CRC32"],
        header_fg: :cyan,
        border_fg: :dark_gray
      )

      rows.each { |r| table.row(r) }

      cols = begin
        [Opal::Terminal.default_driver.size[0] - 2, 90].max
      rescue
        90
      end

      puts "\e[1;36m=== Bakelite Files: #{target} ===\e[0m"
      puts table.to_print_s(width: cols)
      puts "\e[90mTotal Files: #{rows.size} | Uncompressed: #{format_size(total_uncompressed)} | Compressed: #{format_size(total_compressed)}\e[0m"
    end

    private def self.run_inspect(args : Array(String))
      target = args.first?
      unless target && File.exists?(target)
        STDERR.puts "\e[31mError:\e[0m Missing or invalid target file."
        exit 1
      end

      reader = Container::Reader.new(target)
      volumes = reader.read
      trailer = reader.trailer

      unless trailer
        puts "\e[33mNo Bakelite trailer detected in #{target}.\e[0m"
        return
      end

      file_size = File.size(target)
      payload_size = file_size - trailer.volume_start_offset.to_i64

      puts "\e[1;36m=== Bakelite Container Inspection ===\e[0m"
      puts "  Target File:         \e[33m#{target}\e[0m"
      puts "  Total File Size:     #{format_size(file_size)} (#{file_size} bytes)"
      puts "  Host Binary Size:    #{format_size(trailer.volume_start_offset.to_i64)} (#{trailer.volume_start_offset} bytes)"
      puts "  Volume Start Offset: #{trailer.volume_start_offset}"
      puts "  Volume Payload Size: #{format_size(payload_size)} (#{payload_size} bytes)"
      puts "  Index Offset:        +#{trailer.index_offset} (size: #{trailer.index_size} bytes)"
      puts "  Format Version:      v#{trailer.version}"
      puts "  Trailer Magic:       \e[32m#{trailer.magic} (Valid)\e[0m"
      puts "  Mounted Volumes:     \e[1m#{volumes.size}\e[0m"

      volumes.each_with_index do |vol, idx|
        uncomp = vol.items.values.sum(&.size)
        comp = vol.items.values.sum(&.compressed_size)
        puts "    \e[35m[#{idx + 1}] Volume :#{vol.name}\e[0m"
        puts "        Mount Point:   \"#{vol.mount_point}\""
        puts "        Priority:      #{vol.priority}"
        puts "        Files:         #{vol.size}"
        puts "        Uncompressed:  #{format_size(uncomp)}"
        puts "        Compressed:    #{format_size(comp)}"
      end
    end

    private def self.run_verify(args : Array(String))
      target = args.first?
      unless target && File.exists?(target)
        STDERR.puts "\e[31mError:\e[0m Missing or invalid target file."
        exit 1
      end

      reader = Container::Reader.new(target)
      volumes = reader.read

      if volumes.empty?
        STDERR.puts "\e[31mError:\e[0m No Bakelite volumes to verify."
        exit 1
      end

      puts "\e[1;36m=== Verifying Bakelite Integrity: #{target} ===\e[0m"
      errors = 0
      verified_files = 0

      volumes.each do |vol|
        vol.each_file do |item|
          print "  Verifying #{item.path} [:#{vol.name}] ... "
          computed_crc = 0_u32

          begin
            item.open do |stream|
              running_crc = 0_u32
              buffer = Bytes.new(65536)
              while (read_bytes = stream.read(buffer)) > 0
                running_crc = Digest::CRC32.update(buffer[0, read_bytes], running_crc)
              end
              computed_crc = running_crc
            end

            if computed_crc == item.crc32
              puts "\e[32mOK\e[0m (CRC32: #{item.crc32_hex})"
              verified_files += 1
            else
              puts "\e[31mFAILED\e[0m (Expected: #{item.crc32_hex}, Got: #{sprintf("%08x", computed_crc)})"
              errors += 1
            end
          rescue ex
            puts "\e[31mERROR: #{ex.message}\e[0m"
            errors += 1
          end
        end
      end

      if errors == 0
        puts "\e[1;32m✓ All #{verified_files} files verified successfully with zero errors!\e[0m"
      else
        STDERR.puts "\e[1;31m✗ Verification failed with #{errors} error(s)!\e[0m"
        exit 1
      end
    end

    private def self.run_extract(args : Array(String))
      if args.size < 2
        STDERR.puts "Usage: bakelite extract <target> <destination-dir> [--volume NAME]"
        exit 1
      end

      target = args[0]
      dest = args[1]
      selected_volume : String? = nil

      if args.size >= 4 && args[2] == "--volume"
        selected_volume = args[3]
      end

      reader = Container::Reader.new(target)
      volumes = reader.read

      target_vols = if selected_volume
                      volumes.select { |v| v.name == selected_volume }
                    else
                      volumes
                    end

      if target_vols.empty?
        STDERR.puts "\e[31mError:\e[0m No matching volumes found in #{target}."
        exit 1
      end

      puts "\e[1;36m=== Extracting Bakelite Volumes ===\e[0m"
      total_extracted = 0

      target_vols.each do |vol|
        puts "  Extracting volume :#{vol.name} (#{vol.size} files) to #{dest}..."
        count = vol.extract(dest)
        total_extracted += count
      end

      puts "\e[32m✓ Successfully extracted #{total_extracted} files to #{dest}!\e[0m"
    end

    private def self.run_docs(args : Array(String))
      src_dir = "docs_src"
      out_dir = "src/bakelite/docs"
      master_file = "src/bakelite/docs.cr"

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bakelite docs [options]"
        opts.on("--src DIR", "Source directory for markdown/yaml guides") { |s| src_dir = s }
        opts.on("--out DIR", "Output directory for compiled documentation") { |o| out_dir = o }
        opts.on("--master FILE", "Path to master docs index file") { |m| master_file = m }
      end
      parser.parse(args)

      puts "\e[1;36m=== Compiling Documentation with Jasper ===\e[0m"
      puts "  Source: #{src_dir}"
      puts "  Output: #{out_dir}"
      puts "  Master: #{master_file}"

      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(out_dir)

      config = Jasper::Config.new(
        namespace: "Bakelite::Docs",
        source_dir: src_dir,
        output_dir: out_dir,
        master_file: master_file
      )
      config.add_alias("Docs")
      config.set_quick_start("Bakelite Quick Start", [
        "shards install",
        "crystal spec",
        "bin/bakelite pack bin/game.exe assets/ --mount assets",
      ])

      if Jasper::Generator.new(config).run
        puts "\e[32m✓ Documentation compiled successfully!\e[0m"
      else
        puts "\e[33mNo YAML guide files found in #{src_dir} to compile.\e[0m"
      end
    end

    private def self.parse_size(size_str : String) : UInt32
      s = size_str.strip.downcase
      if s.ends_with?("k") || s.ends_with?("kb")
        num = s.rstrip("kb").to_u32
        num * 1024_u32
      elsif s.ends_with?("m") || s.ends_with?("mb")
        num = s.rstrip("mb").to_u32
        num * 1024_u32 * 1024_u32
      else
        s.to_u32
      end
    rescue
      65536_u32
    end

    private def self.format_size(bytes : Int64 | UInt64 | Int32 | UInt32) : String
      b = bytes.to_f
      if b < 1024.0
        "#{b.to_i} B"
      elsif b < 1024.0 * 1024.0
        sprintf("%.1f KB", b / 1024.0)
      elsif b < 1024.0 * 1024.0 * 1024.0
        sprintf("%.1f MB", b / (1024.0 * 1024.0))
      else
        sprintf("%.2f GB", b / (1024.0 * 1024.0 * 1024.0))
      end
    end
  end
end

Bakelite::CLI.run
