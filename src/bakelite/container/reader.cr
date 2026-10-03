require "path"
require "./format"
require "../types"
require "../item"
require "../volume"

module Bakelite
  module Container
    # Parses standalone .bkl archives or appended executable volumes.
    # Reads the 32-byte trailer at the end of the file, directly loads the file index,
    # and constructs StoredItems that stream chunks from the container file on demand.
    class Reader
      getter target_path : Path
      getter trailer : Trailer?
      getter volumes : Array(Volume)

      def initialize(target_path : Path | String)
        @target_path = Path.new(target_path.to_s)
        @volumes = [] of Volume
        @trailer = nil
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

      # Parses the container and returns all extracted volumes.
      def read : Array(Volume)
        return @volumes unless @volumes.empty?

        raise "File not found: #{@target_path}" unless File.exists?(@target_path)
        file_size = File.size(@target_path)
        raise "File too small to contain Bakelite trailer" if file_size < TRAILER_SIZE

        # Open file in read-only binary mode for reading index and streaming chunks
        io = File.open(@target_path, "rb")

        # 1. Read Trailer
        io.seek(file_size - TRAILER_SIZE, IO::Seek::Set)
        trailer = Trailer.read(io) || raise "Invalid or corrupt Bakelite trailer in #{@target_path}"
        @trailer = trailer

        # 2. Seek to Volume Header and Read Volume Table
        io.seek(trailer.volume_start_offset.to_i64, IO::Seek::Set)
        magic_buf = Bytes.new(8)
        io.read_fully(magic_buf)
        raise "Invalid Bakelite volume header" unless String.new(magic_buf) == MAGIC_HEADER

        _ver = io.read_bytes(UInt16, BYTE_FORMAT)
        vol_count = io.read_bytes(UInt16, BYTE_FORMAT)

        volumes_map = Hash(String, Volume).new
        vol_count.times do
          v_name = read_string(io)
          v_mount = read_string(io)
          v_priority = io.read_bytes(Int32, BYTE_FORMAT)
          v_chunk_size = io.read_bytes(UInt32, BYTE_FORMAT)
          v_comp = CompressionType.new(io.read_bytes(UInt8, BYTE_FORMAT))

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

        # 3. Seek to Index Section
        index_abs_offset = (trailer.volume_start_offset + trailer.index_offset).to_i64
        io.seek(index_abs_offset, IO::Seek::Set)

        total_files = io.read_bytes(UInt32, BYTE_FORMAT)

        total_files.times do
          f_path = read_string(io)
          f_vol_name = read_string(io)
          f_size = io.read_bytes(UInt64, BYTE_FORMAT).to_i64
          f_comp_size = io.read_bytes(UInt64, BYTE_FORMAT).to_i64
          _f_mode = StorageMode.new(io.read_bytes(UInt8, BYTE_FORMAT))
          f_comp = CompressionType.new(io.read_bytes(UInt8, BYTE_FORMAT))
          f_mime = read_string(io)
          f_crc = io.read_bytes(UInt32, BYTE_FORMAT)

          chunk_count = io.read_bytes(UInt32, BYTE_FORMAT)
          chunks = [] of Chunk

          chunk_count.times do
            rel_offset = io.read_bytes(UInt64, BYTE_FORMAT)
            comp_sz = io.read_bytes(UInt32, BYTE_FORMAT)
            uncomp_sz = io.read_bytes(UInt32, BYTE_FORMAT)
            crc = io.read_bytes(UInt32, BYTE_FORMAT)

            # Absolute offset in container file
            abs_offset = (trailer.volume_start_offset + rel_offset).to_i64

            chunks << Chunk.new(
              offset: abs_offset,
              compressed_size: comp_sz,
              uncompressed_size: uncomp_sz,
              crc32: crc
            )
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

        @volumes
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

      private def read_string(io : IO) : String
        len = io.read_bytes(UInt16, BYTE_FORMAT)
        buf = Bytes.new(len)
        io.read_fully(buf)
        String.new(buf)
      end
    end
  end
end
