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

    # Reads an arbitrary IO stream in chunks of chunk_size and compresses each chunk.
    # Yields each chunk to the provided block as soon as it is generated, maintaining
    # strict O(chunk_size) peak RAM usage even for multi-gigabyte streams.
    # Returns a Tuple containing the Array of Chunk descriptors and the total uncompressed CRC32.
    def self.chunk_stream(
      io : IO,
      total_size : Int64,
      chunk_size : UInt32 = 65536_u32,
      compression : CompressionType = CompressionType::Deflate,
      base_offset : Int64 = 0_i64,
      &block : Chunk ->
    ) : Tuple(Array(Chunk), UInt32)
      chunks = [] of Chunk
      buffer = Bytes.new(chunk_size.to_i32)
      running_offset = base_offset
      bytes_remaining = total_size
      running_crc = Digest::CRC32.initial

      while bytes_remaining > 0
        read_len = Math.min(buffer.size.to_i64, bytes_remaining).to_i32
        actual_read = io.read_fully?(buffer[0, read_len]) || 0
        break if actual_read == 0

        uncompressed_slice = buffer[0, actual_read]
        running_crc = Digest::CRC32.update(uncompressed_slice, running_crc)
        chunk_crc32 = Digest::CRC32.checksum(uncompressed_slice)
        compressed_bytes = compress_slice(uncompressed_slice, compression)

        chunk = Chunk.new(
          offset: running_offset,
          compressed_size: compressed_bytes.size.to_u32,
          uncompressed_size: actual_read.to_u32,
          crc32: chunk_crc32,
          data: compressed_bytes
        )

        yield chunk
        chunks << chunk
        running_offset += compressed_bytes.size
        bytes_remaining -= actual_read
      end

      {chunks, running_crc}
    end

    # Overload for chunk_stream when block is not provided
    def self.chunk_stream(
      io : IO,
      total_size : Int64,
      chunk_size : UInt32 = 65536_u32,
      compression : CompressionType = CompressionType::Deflate,
      base_offset : Int64 = 0_i64,
    ) : Tuple(Array(Chunk), UInt32)
      chunk_stream(io, total_size, chunk_size, compression, base_offset) { |_| }
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
