require "compress/deflate"
require "compress/gzip"
require "compress/zlib"
require "./types"

module Bakelite
  # Thread-safe synchronized IO wrapper providing atomic seek-and-read operations
  # for concurrent readers accessing the same container source.
  class SynchronizedIO < IO
    getter io : IO
    getter mutex : ::Thread::Mutex

    def initialize(@io : IO, @mutex : ::Thread::Mutex = ::Thread::Mutex.new)
    end

    def read(slice : Bytes) : Int32
      @mutex.synchronize { @io.read(slice) }
    end

    def write(slice : Bytes) : Nil
      @mutex.synchronize { @io.write(slice) }
    end

    def seek(offset : Int, whence : IO::Seek = IO::Seek::Set) : self
      @mutex.synchronize { @io.seek(offset, whence) }
      self
    end

    def pos : Int64
      @mutex.synchronize { @io.pos.to_i64 }
    end

    # Atomically seeks to offset and reads exact slice
    def read_at(offset : Int64, slice : Bytes) : Nil
      @mutex.synchronize do
        if @io.responds_to?(:seek)
          @io.seek(offset, IO::Seek::Set)
        end
        @io.read_fully(slice)
      end
    end

    def close : Nil
      @mutex.synchronize { @io.close }
    end

    def closed? : Bool
      @mutex.synchronize { @io.closed? }
    end
  end

  # High-performance, read-only streaming IO implementation for Bakelite stored assets.
  # Decompresses chunks on demand into a single active sliding buffer, ensuring peak
  # memory usage remains strictly O(chunk_size) regardless of file size.
  class FileIO < IO
    getter size : Int64
    getter pos : Int64 = 0_i64
    getter compression : CompressionType
    getter? closed : Bool = false

    @chunks : Array(Chunk)
    @chunk_offsets : Array(Int64)
    @underlying_io : IO?
    @active_chunk_index : Int32 = -1
    @active_chunk_data : Bytes = Bytes.empty

    def initialize(
      @chunks : Array(Chunk),
      @size : Int64,
      @compression : CompressionType = CompressionType::None,
      @underlying_io : IO? = nil,
    )
      # Precompute uncompressed starting offsets for O(1) binary/linear chunk search
      running_offset = 0_i64
      @chunk_offsets = Array(Int64).new(@chunks.size)
      @chunks.each do |chunk|
        @chunk_offsets << running_offset
        running_offset += chunk.uncompressed_size
      end
    end

    # Reads up to slice.size bytes into slice. Returns number of bytes read (0 on EOF).
    def read(slice : Bytes) : Int32
      check_open
      return 0 if @pos >= @size || slice.empty?

      # Find which chunk contains @pos
      chunk_idx = find_chunk_index(@pos)
      return 0 if chunk_idx < 0 || chunk_idx >= @chunks.size

      # Ensure chunk is loaded and decompressed
      ensure_chunk_loaded(chunk_idx)

      # Determine slice inside active chunk
      chunk_start_pos = @chunk_offsets[chunk_idx]
      offset_in_chunk = (@pos - chunk_start_pos).to_i32
      available_in_chunk = @active_chunk_data.size - offset_in_chunk

      return 0 if available_in_chunk <= 0

      # Determine bytes to copy in this read call
      to_copy = Math.min(slice.size, available_in_chunk)
      # Do not read past the logical uncompressed size
      remaining_in_file = (@size - @pos).to_i64
      to_copy = Math.min(to_copy.to_i64, remaining_in_file).to_i32

      slice[0, to_copy].copy_from(@active_chunk_data[offset_in_chunk, to_copy])
      @pos += to_copy
      to_copy
    end

    # Seeking support: Set, Current, or End
    def seek(offset : Int, whence : IO::Seek = IO::Seek::Set) : self
      check_open
      off = offset.to_i64
      target = case whence
               when IO::Seek::Set
                 off
               when IO::Seek::Current
                 @pos + off
               when IO::Seek::End
                 @size + off
               else
                 raise ArgumentError.new("Invalid seek whence: #{whence}")
               end

      raise ArgumentError.new("Negative seek position: #{target}") if target < 0
      @pos = target

      # Invalidate active chunk if new position is outside active chunk boundary
      if @active_chunk_index >= 0
        chunk_start = @chunk_offsets[@active_chunk_index]
        chunk_end = chunk_start + @active_chunk_data.size
        if @pos < chunk_start || @pos >= chunk_end
          @active_chunk_index = -1
          @active_chunk_data = Bytes.empty
        end
      end

      self
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("Bakelite::FileIO is read-only")
    end

    def close : Nil
      @closed = true
      @active_chunk_data = Bytes.empty
      @active_chunk_index = -1
    end

    private def check_open : Nil
      raise IO::Error.new("Closed stream") if @closed
    end

    # Finds the index of the chunk that contains the specified uncompressed position
    private def find_chunk_index(target_pos : Int64) : Int32
      return -1 if target_pos >= @size

      # Binary search over precomputed chunk offsets
      low = 0
      high = @chunk_offsets.size - 1

      while low <= high
        mid = (low + high) // 2
        chunk_start = @chunk_offsets[mid]
        chunk_len = @chunks[mid].uncompressed_size
        chunk_end = chunk_start + chunk_len

        if target_pos < chunk_start
          high = mid - 1
        elsif target_pos >= chunk_end
          low = mid + 1
        else
          return mid
        end
      end

      -1
    end

    # Loads and decompresses the given chunk if it is not already in memory
    private def ensure_chunk_loaded(index : Int32) : Nil
      return if @active_chunk_index == index && !@active_chunk_data.empty?

      chunk = @chunks[index]
      raw_bytes = fetch_raw_chunk_bytes(chunk)

      @active_chunk_data = decompress_chunk(raw_bytes, chunk.uncompressed_size)
      @active_chunk_index = index
    end

    # Fetches raw compressed (or uncompressed) bytes for a chunk
    private def fetch_raw_chunk_bytes(chunk : Chunk) : Bytes
      if data = chunk.data
        return data
      end

      if io = @underlying_io
        buffer = Bytes.new(chunk.compressed_size)
        if io.is_a?(SynchronizedIO)
          io.read_at(chunk.offset, buffer)
        else
          if io.responds_to?(:seek)
            io.seek(chunk.offset, IO::Seek::Set)
          end
          io.read_fully(buffer)
        end
        return buffer
      end

      raise IO::Error.new("Chunk has neither in-memory data nor underlying IO source!")
    end

    # Decompresses raw chunk data according to compression algorithm
    private def decompress_chunk(raw : Bytes, expected_uncompressed_size : UInt32) : Bytes
      case @compression
      when CompressionType::None
        raw
      when CompressionType::Deflate
        memory_in = IO::Memory.new(raw)
        Compress::Deflate::Reader.open(memory_in) do |deflate|
          buf = Bytes.new(expected_uncompressed_size)
          deflate.read_fully(buf)
          buf
        end
      when CompressionType::Zlib
        memory_in = IO::Memory.new(raw)
        Compress::Zlib::Reader.open(memory_in) do |zlib|
          buf = Bytes.new(expected_uncompressed_size)
          zlib.read_fully(buf)
          buf
        end
      when CompressionType::Gzip
        memory_in = IO::Memory.new(raw)
        Compress::Gzip::Reader.open(memory_in) do |gzip|
          buf = Bytes.new(expected_uncompressed_size)
          gzip.read_fully(buf)
          buf
        end
      else
        raw
      end
    end
  end
end
