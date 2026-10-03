require "file_utils"
require "path"
require "digest/crc32"
require "./format"
require "../types"
require "../chunker"
require "../mime"
require "../volume"

module Bakelite
  module Container
    # Packs files into a standalone .bkl container or appends a Bakelite volume
    # directly onto the end of an existing executable image.
    class Writer
      getter target_path : Path
      getter volumes : Array(Volume)

      def initialize(target_path : Path | String)
        @target_path = Path.new(target_path.to_s)
        @volumes = [] of Volume
      end

      # Adds a volume to be written into the container.
      def add_volume(volume : Volume) : self
        @volumes << volume
        self
      end

      # Packs a directory into a named volume.
      def pack_directory(
        source_dir : Path | String,
        volume_name : Symbol | String = :root,
        mount_point : String = "",
        priority : Int32 = 0,
        chunk_size : UInt32 = 65536_u32,
        compression : CompressionType = CompressionType::Deflate,
        exclude : Array(String) = [] of String,
      ) : self
        vol = Volume.new(
          name: volume_name,
          mount_point: mount_point,
          priority: priority,
          default_chunk_size: chunk_size,
          default_compression: compression
        )

        dir_path = Path.new(source_dir.to_s)
        pattern = File.join(dir_path, "**/*").tr("\\", "/")

        Dir.glob(pattern).sort.each do |file_match|
          next unless File.file?(file_match)
          rel = Path.new(file_match).relative_to(dir_path).to_s.tr("\\", "/")

          # Exclusion check
          excluded = exclude.any? do |ex|
            File.match?(ex.tr("\\", "/"), rel) || rel.includes?(ex)
          end
          next if excluded

          file_size = File.size(file_match)
          chunks = [] of Chunk
          running_crc = 0_u32

          File.open(file_match, "rb") do |file_io|
            chunks, running_crc = Chunker.chunk_stream(
              io: file_io,
              total_size: file_size,
              chunk_size: chunk_size,
              compression: compression
            )
          end

          total_comp = chunks.sum(&.compressed_size.to_i64)

          item = StoredItem.new(
            path: rel,
            volume_name: volume_name,
            size: file_size,
            compressed_size: total_comp,
            chunks: chunks,
            compression: compression,
            crc32: running_crc
          )

          vol.add(item)
        end

        add_volume(vol)
        self
      end

      # Streams and packs an arbitrary IO stream into a named volume.
      def pack_stream(
        io : IO,
        size : Int64,
        virtual_path : String,
        volume_name : Symbol | String = :root,
        mount_point : String = "",
        priority : Int32 = 0,
        chunk_size : UInt32 = 65536_u32,
        compression : CompressionType = CompressionType::Deflate,
      ) : self
        vol = find_or_create_volume(
          name: volume_name,
          mount_point: mount_point,
          priority: priority,
          default_chunk_size: chunk_size,
          default_compression: compression
        )

        chunks, running_crc = Chunker.chunk_stream(
          io: io,
          total_size: size,
          chunk_size: chunk_size,
          compression: compression
        )

        total_comp = chunks.sum(&.compressed_size.to_i64)

        item = StoredItem.new(
          path: virtual_path,
          volume_name: volume_name,
          size: size,
          compressed_size: total_comp,
          chunks: chunks,
          compression: compression,
          crc32: running_crc
        )

        vol.add(item)
        self
      end

      # Finds an existing volume by name or creates and mounts a new one.
      def find_or_create_volume(
        name : Symbol | String,
        mount_point : String = "",
        priority : Int32 = 0,
        default_chunk_size : UInt32 = 65536_u32,
        default_compression : CompressionType = CompressionType::Deflate,
      ) : Volume
        key = name.to_s
        if existing = @volumes.find { |v| v.name == key }
          existing
        else
          vol = Volume.new(
            name: key,
            mount_point: mount_point,
            priority: priority,
            default_chunk_size: default_chunk_size,
            default_compression: default_compression
          )
          add_volume(vol)
          vol
        end
      end

      # Executes the pack operation. Appends to target if it already exists, or creates it anew.
      def write(append : Bool = true) : Int64
        mode = if File.exists?(@target_path) && append
                 "r+b"
               else
                 "wb"
               end

        FileUtils.mkdir_p(@target_path.parent)

        File.open(@target_path, mode) do |io|
          volume_start_offset = io.size.to_u64
          io.seek(volume_start_offset.to_i64, IO::Seek::Set)

          # 1. Volume Header
          io.write(MAGIC_HEADER.to_slice)
          io.write_bytes(FORMAT_VERSION, BYTE_FORMAT)
          io.write_bytes(@volumes.size.to_u16, BYTE_FORMAT)

          # Write volume descriptors
          @volumes.each do |vol|
            write_string(io, vol.name.to_s)
            write_string(io, vol.mount_point)
            io.write_bytes(vol.priority, BYTE_FORMAT)
            io.write_bytes(vol.default_chunk_size, BYTE_FORMAT)
            io.write_bytes(vol.default_compression.value, BYTE_FORMAT)
          end

          # 2. Sequential Chunk Payloads
          # Record final relative offsets within volume
          file_chunk_tables = Hash(Item, Array(Chunk)).new

          @volumes.each do |vol|
            vol.each_file do |item|
              chunks = if item.is_a?(StoredItem)
                         item.chunks
                       else
                         # Convert baked item to a single chunk
                         slice = item.to_slice
                         comp = Chunker.compress_slice(slice, vol.default_compression)
                         [Chunk.new(
                           offset: 0_i64,
                           compressed_size: comp.size.to_u32,
                           uncompressed_size: slice.size.to_u32,
                           crc32: item.crc32,
                           data: comp
                         )]
                       end

              final_chunks = [] of Chunk
              chunks.each do |chunk|
                chunk_offset_in_volume = (io.pos - volume_start_offset).to_i64
                if chunk_bytes = chunk.data
                  io.write(chunk_bytes)
                else
                  raise "Chunk data missing during container writing"
                end

                final_chunks << Chunk.new(
                  offset: chunk_offset_in_volume,
                  compressed_size: chunk.compressed_size,
                  uncompressed_size: chunk.uncompressed_size,
                  crc32: chunk.crc32
                )
              end

              file_chunk_tables[item] = final_chunks
            end
          end

          # 3. File Index
          index_offset = (io.pos - volume_start_offset).to_u64

          # Total file count across all volumes
          total_files = @volumes.sum(&.size).to_u32
          io.write_bytes(total_files, BYTE_FORMAT)

          @volumes.each do |vol|
            vol.each_file do |item|
              chunks = file_chunk_tables[item]

              write_string(io, item.path)
              write_string(io, vol.name.to_s)
              io.write_bytes(item.size.to_u64, BYTE_FORMAT)
              io.write_bytes(item.compressed_size.to_u64, BYTE_FORMAT)
              io.write_bytes(item.storage_mode.value, BYTE_FORMAT)
              comp_val = item.is_a?(StoredItem) ? item.compression.value : vol.default_compression.value
              io.write_bytes(comp_val, BYTE_FORMAT)
              write_string(io, item.mime_type)
              io.write_bytes(item.crc32, BYTE_FORMAT)

              # Chunks table
              io.write_bytes(chunks.size.to_u32, BYTE_FORMAT)
              chunks.each do |chk|
                io.write_bytes(chk.offset.to_u64, BYTE_FORMAT)
                io.write_bytes(chk.compressed_size, BYTE_FORMAT)
                io.write_bytes(chk.uncompressed_size, BYTE_FORMAT)
                io.write_bytes(chk.crc32, BYTE_FORMAT)
              end
            end
          end

          index_size = (io.pos - (volume_start_offset + index_offset)).to_u64

          # 4. 32-Byte Trailer at EOF
          trailer = Trailer.new(
            volume_start_offset: volume_start_offset,
            index_offset: index_offset,
            index_size: index_size,
            version: FORMAT_VERSION,
            magic: MAGIC_TRAILER
          )
          trailer.write(io)
          io.flush

          (io.pos - volume_start_offset).to_i64
        end
      end

      private def write_string(io : IO, str : String) : Nil
        bytes = str.to_slice
        io.write_bytes(bytes.size.to_u16, BYTE_FORMAT)
        io.write(bytes)
      end
    end
  end
end
