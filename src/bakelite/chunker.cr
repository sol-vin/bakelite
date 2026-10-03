require "compress/deflate"
require "compress/gzip"
require "compress/zlib"
require "digest/crc32"
require "./types"

module Bakelite
  # Utility module for splitting large files into compressed chunks.
  module Chunker
    # Splits input byte slice into an array of compressed chunks of chunk_size.
    def self.chunk_data(
      data : Bytes,
      chunk_size : UInt32 = 65536_u32,
      compression : CompressionType = CompressionType::Deflate,
      base_offset : Int64 = 0_i64,
    ) : Array(Chunk)
      chunks = [] of Chunk
      total_bytes = data.size
      current_pos = 0
      running_offset = base_offset

      while current_pos < total_bytes
        slice_len = Math.min(chunk_size.to_i32, total_bytes - current_pos)
        uncompressed_slice = data[current_pos, slice_len]

        chunk_crc32 = Digest::CRC32.checksum(uncompressed_slice)
        compressed_bytes = compress_slice(uncompressed_slice, compression)

        chunk = Chunk.new(
          offset: running_offset,
          compressed_size: compressed_bytes.size.to_u32,
          uncompressed_size: slice_len.to_u32,
          crc32: chunk_crc32,
          data: compressed_bytes
        )

        chunks << chunk
        running_offset += compressed_bytes.size
        current_pos += slice_len
      end

      chunks
    end

    # Compresses a raw byte slice using the requested algorithm.
    def self.compress_slice(slice : Bytes, compression : CompressionType) : Bytes
      case compression
      when CompressionType::None
        slice
      when CompressionType::Deflate
        memory_out = IO::Memory.new
        Compress::Deflate::Writer.open(memory_out) do |deflate|
          deflate.write(slice)
        end
        memory_out.to_slice
      when CompressionType::Zlib
        memory_out = IO::Memory.new
        Compress::Zlib::Writer.open(memory_out) do |zlib|
          zlib.write(slice)
        end
        memory_out.to_slice
      when CompressionType::Gzip
        memory_out = IO::Memory.new
        Compress::Gzip::Writer.open(memory_out) do |gzip|
          gzip.write(slice)
        end
        memory_out.to_slice
      else
        slice
      end
    end
  end
end
