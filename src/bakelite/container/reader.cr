require "path"
require "./format"
require "../types"
require "../item"
require "../volume"

module Bakelite
  module Container
    # Parses standalone .bkl archives, appended executable volumes, or in-memory container buffers.
    # Reads the 32-byte trailer at the end of the container, validates all header/index bounds,
    # and constructs StoredItems that stream chunks from the container source on demand.
    class Reader
      getter target_path : Path
      getter trailer : Trailer?
      getter volumes : Array(Volume)
      @source_bytes : Bytes?
      @source_io : IO?
      @source_size : Int64?
      @synchronized_io : SynchronizedIO?
      @owns_io : Bool = false

      def initialize(target_path : Path | String)
        @target_path = Path.new(target_path.to_s)
        @volumes = [] of Volume
        @trailer = nil
        @source_bytes = nil
        @source_io = nil
        @source_size = nil
      end

      def initialize(bytes : Bytes, source_name : String = "<memory>")
        @target_path = Path.new(source_name)
        @volumes = [] of Volume
        @trailer = nil
        @source_bytes = bytes
        @source_io = nil
        @source_size = bytes.size.to_i64
      end

      def initialize(io : IO, size : Int64? = nil, source_name : String = "<stream>")
        @target_path = Path.new(source_name)
        @volumes = [] of Volume
        @trailer = nil
        @source_bytes = nil
        @source_io = io
        @source_size = size
      end

      def self.from_bytes(bytes : Bytes, source_name : String = "<memory>") : self
        new(bytes, source_name)
      end

      def self.from_io(io : IO, size : Int64? = nil, source_name : String = "<stream>") : self
        new(io, size, source_name)
      end

      # Checks whether the target file contains a valid Bakelite volume trailer.
      def self.has_trailer?(file_path : Path | String) : Bool
        path = Path.new(file_path.to_s)
        return false unless File.exists?(path)
        file_size = File.size(path)
        return false if file_size < TRAILER_SIZE

        File.open(path, "rb") do |io|
          io.seek(file_size - TRAILER_SIZE, IO::Seek::Set)
          !Trailer.read(io).nil?
        end
      rescue
        false
      end

      # Checks whether an in-memory byte slice contains a valid Bakelite volume trailer.
      def self.has_trailer?(bytes : Bytes) : Bool
        return false if bytes.size < TRAILER_SIZE
        mem = IO::Memory.new(bytes[bytes.size - TRAILER_SIZE.to_i32, TRAILER_SIZE.to_i32], writable: false)
        !Trailer.read(mem).nil?
      rescue
        false
      end

      # Closes the underlying container IO if owned by this Reader.
      def close : Nil
        if sync_io = @synchronized_io
          sync_io.close if @owns_io && !sync_io.closed?
          @synchronized_io = nil
        end
      end

      # Parses the container and returns all extracted volumes.
      def read : Array(Volume)
        return @volumes unless @volumes.empty?

        raw_io : IO
        file_size : Int64

        if bytes = @source_bytes
          file_size = bytes.size.to_i64
          raise InvalidTrailerError.new("Container buffer too small to contain Bakelite trailer: #{file_size} bytes") if file_size < TRAILER_SIZE
          raw_io = IO::Memory.new(bytes, writable: false)
          @owns_io = true
        elsif src_io = @source_io
          file_size = @source_size || begin
            if src_io.responds_to?(:size)
              src_io.size.to_i64
            else
              raise ArgumentError.new("Stream size must be provided when reading container from unsized IO")
            end
          end
          raise InvalidTrailerError.new("Container stream too small to contain Bakelite trailer: #{file_size} bytes") if file_size < TRAILER_SIZE
          raw_io = src_io
          @owns_io = false
        else
          raise File::NotFoundError.new("File not found", file: @target_path) unless File.exists?(@target_path)
          file_size = File.size(@target_path)
          raise InvalidTrailerError.new("File too small to contain Bakelite trailer: #{file_size} bytes") if file_size < TRAILER_SIZE
          raw_io = File.open(@target_path, "rb")
          @owns_io = true
        end

        io = SynchronizedIO.new(raw_io)
        @synchronized_io = io

        begin
          parse_container!(io, file_size)
        rescue ex : Error
          close
          @volumes.clear
          raise ex
        rescue ex : IO::EOFError | OverflowError | ArgumentError | IndexError
          close
          @volumes.clear
          raise CorruptContainerError.new("Malformed or truncated Bakelite container in #{@target_path}: #{ex.message}")
        end

        @volumes
      end

      private def parse_container!(io : SynchronizedIO, file_size : Int64) : Nil
        payload_end = (file_size - TRAILER_SIZE).to_u64

        # 1. Read Trailer
        io.seek(file_size - TRAILER_SIZE, IO::Seek::Set)
        trailer = Trailer.read(io) || raise InvalidTrailerError.new("Invalid or corrupt Bakelite trailer in #{@target_path}")
        @trailer = trailer

        # Validate trailer offsets against container bounds (overflow-safe)
        if trailer.volume_start_offset > payload_end
          raise CorruptContainerError.new("Trailer volume_start_offset (#{trailer.volume_start_offset}) exceeds container bounds (#{payload_end})")
        end

        volume_payload_len = payload_end - trailer.volume_start_offset
        if volume_payload_len < 12_u64
          raise CorruptContainerError.new("Bakelite volume section too small for header (#{volume_payload_len} bytes)")
        end

        if trailer.index_offset > volume_payload_len
          raise CorruptContainerError.new("Trailer index_offset (#{trailer.index_offset}) exceeds volume payload bounds (#{volume_payload_len})")
        end

        index_abs_u64 = trailer.volume_start_offset + trailer.index_offset
        if trailer.index_size < 4_u64 || trailer.index_size > (payload_end - index_abs_u64)
          raise CorruptContainerError.new("Trailer index_size (#{trailer.index_size}) is invalid or exceeds container bounds")
        end

        # 2. Seek to Volume Header and Read Volume Table
        io.seek(trailer.volume_start_offset.to_i64, IO::Seek::Set)
        magic_buf = Bytes.new(8)
        io.read_fully(magic_buf)
        raise CorruptContainerError.new("Invalid Bakelite volume header magic in #{@target_path}") unless String.new(magic_buf) == MAGIC_HEADER

        header_ver = io.read_bytes(UInt16, BYTE_FORMAT)
        raise CorruptContainerError.new("Unsupported Bakelite volume header version: #{header_ver}") unless header_ver == FORMAT_VERSION

        vol_count = io.read_bytes(UInt16, BYTE_FORMAT)
        # Each volume descriptor requires at least 13 bytes (2+2+4+4+1)
        if vol_count.to_u64 * 13_u64 > (index_abs_u64 - io.pos.to_u64)
          raise CorruptContainerError.new("Corrupt volume count (#{vol_count}) exceeds header bounds")
        end

        volumes_map = Hash(String, Volume).new
        vol_count.times do
          v_name = read_string(io, index_abs_u64.to_i64)
          v_mount = read_string(io, index_abs_u64.to_i64)
          v_priority = io.read_bytes(Int32, BYTE_FORMAT)
          v_chunk_size = io.read_bytes(UInt32, BYTE_FORMAT)
          raise CorruptContainerError.new("Invalid zero default_chunk_size in volume header") if v_chunk_size == 0_u32

          comp_raw = io.read_bytes(UInt8, BYTE_FORMAT)
          v_comp = CompressionType.from_value?(comp_raw) || raise CorruptContainerError.new("Invalid volume compression type byte: #{comp_raw}")

          vol = Volume.new(
            name: v_name,
            mount_point: v_mount,
            priority: v_priority,
            default_chunk_size: v_chunk_size,
            default_compression: v_comp
          )
          volumes_map[v_name] = vol
          @volumes << vol
        end

        data_start_rel_u64 = (io.pos.to_u64 - trailer.volume_start_offset)
        if data_start_rel_u64 > trailer.index_offset
          raise CorruptContainerError.new("Volume descriptor table overlaps index section")
        end

        # 3. Seek to Index Section
        index_abs_offset = index_abs_u64.to_i64
        index_end_offset = (index_abs_u64 + trailer.index_size).to_i64
        io.seek(index_abs_offset, IO::Seek::Set)

        total_files = io.read_bytes(UInt32, BYTE_FORMAT)
        # Each file descriptor requires at least 32 bytes (2+2+8+8+1+1+2+4+4)
        if total_files.to_u64 * 32_u64 > (index_end_offset - io.pos).to_u64
          raise CorruptContainerError.new("Corrupt total_files count (#{total_files}) exceeds index bounds")
        end

        total_files.times do
          f_path = read_string(io, index_end_offset)
          f_vol_name = read_string(io, index_end_offset)
          f_size_u64 = io.read_bytes(UInt64, BYTE_FORMAT)
          f_comp_size_u64 = io.read_bytes(UInt64, BYTE_FORMAT)

          if f_size_u64 > Int64::MAX.to_u64 || f_comp_size_u64 > Int64::MAX.to_u64
            raise CorruptContainerError.new("File size overflow in index for '#{f_path}'")
          end
          f_size = f_size_u64.to_i64
          f_comp_size = f_comp_size_u64.to_i64

          mode_raw = io.read_bytes(UInt8, BYTE_FORMAT)
          _f_mode = StorageMode.from_value?(mode_raw) || raise CorruptContainerError.new("Invalid storage mode byte: #{mode_raw}")

          comp_raw = io.read_bytes(UInt8, BYTE_FORMAT)
          f_comp = CompressionType.from_value?(comp_raw) || raise CorruptContainerError.new("Invalid file compression type byte: #{comp_raw}")

          f_mime = read_string(io, index_end_offset)
          f_crc = io.read_bytes(UInt32, BYTE_FORMAT)

          chunk_count = io.read_bytes(UInt32, BYTE_FORMAT)
          # Each chunk entry is exactly 20 bytes (8+4+4+4)
          if chunk_count.to_u64 * 20_u64 > (index_end_offset - io.pos).to_u64
            raise CorruptContainerError.new("Corrupt chunk_count (#{chunk_count}) exceeds index bounds for '#{f_path}'")
          end

          chunks = Array(Chunk).new(chunk_count.to_i32)
          sum_uncomp_u64 = 0_u64
          sum_comp_u64 = 0_u64

          chunk_count.times do
            rel_offset = io.read_bytes(UInt64, BYTE_FORMAT)
            comp_sz = io.read_bytes(UInt32, BYTE_FORMAT)
            uncomp_sz = io.read_bytes(UInt32, BYTE_FORMAT)
            crc = io.read_bytes(UInt32, BYTE_FORMAT)

            if rel_offset < data_start_rel_u64 || rel_offset > trailer.index_offset
              raise CorruptContainerError.new("Chunk relative offset (#{rel_offset}) out of payload bounds for '#{f_path}'")
            end
            if comp_sz.to_u64 > (trailer.index_offset - rel_offset)
              raise CorruptContainerError.new("Chunk compressed size (#{comp_sz}) exceeds payload bounds for '#{f_path}'")
            end
            if f_comp.none? && comp_sz != uncomp_sz
              raise CorruptContainerError.new("Uncompressed chunk has mismatched compressed (#{comp_sz}) and uncompressed (#{uncomp_sz}) sizes")
            end

            sum_uncomp_u64 += uncomp_sz.to_u64
            sum_comp_u64 += comp_sz.to_u64

            # Absolute offset in container file
            abs_offset = (trailer.volume_start_offset + rel_offset).to_i64

            chunks << Chunk.new(
              offset: abs_offset,
              compressed_size: comp_sz,
              uncompressed_size: uncomp_sz,
              crc32: crc
            )
          end

          if sum_uncomp_u64 != f_size_u64
            raise CorruptContainerError.new("Chunk uncompressed size sum (#{sum_uncomp_u64}) does not match file size (#{f_size_u64}) for '#{f_path}'")
          end
          if sum_comp_u64 != f_comp_size_u64
            raise CorruptContainerError.new("Chunk compressed size sum (#{sum_comp_u64}) does not match compressed file size (#{f_comp_size_u64}) for '#{f_path}'")
          end

          vol = volumes_map[f_vol_name]? || begin
            v = Volume.new(f_vol_name)
            volumes_map[f_vol_name] = v
            @volumes << v
            v
          end

          item = StoredItem.new(
            path: f_path,
            volume_name: f_vol_name,
            size: f_size,
            compressed_size: f_comp_size,
            chunks: chunks,
            compression: f_comp,
            mime_type: f_mime,
            crc32: f_crc,
            underlying_io: io
          )

          vol.add(item)
        end

        if io.pos != index_end_offset
          raise CorruptContainerError.new("Index section size mismatch (expected end at #{index_end_offset}, got #{io.pos})")
        end
      end

      # High-level helper to mount volumes from an archive file into a registry.
      def self.mount(
        registry : FS::Registry,
        archive_path : String | Path,
        volume_name : Symbol | String | Nil = nil,
        mount : String? = nil,
        priority : Int32 = 0,
      ) : Volume?
        return nil unless has_trailer?(archive_path)

        reader = new(archive_path)
        vols = reader.read
        return nil if vols.empty?

        vols.each do |v|
          v.priority = priority if priority != 0
          v.mount_point = mount if mount
          registry.mount(v)
        end

        vols.first?
      end

      private def read_string(io : IO, max_pos : Int64) : String
        raise CorruptContainerError.new("Unexpected end of section while reading string length") if io.pos + 2 > max_pos
        len = io.read_bytes(UInt16, BYTE_FORMAT)
        raise CorruptContainerError.new("String length (#{len}) exceeds section bounds") if io.pos + len.to_i64 > max_pos
        buf = Bytes.new(len)
        io.read_fully(buf)
        String.new(buf)
      end
    end
  end
end
