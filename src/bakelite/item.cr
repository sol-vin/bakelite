require "file_utils"
require "path"
require "digest/crc32"
require "./types"
require "./file_io"
require "./mime"

module Bakelite
  # Abstract representation of an embedded or stored virtual file.
  abstract class Item
    getter path : String
    getter volume_name : String
    getter size : Int64
    getter compressed_size : Int64
    getter mime_type : String
    getter crc32 : UInt32
    getter storage_mode : StorageMode

    def initialize(
      @path : String,
      volume_name : Symbol | String,
      @size : Int64,
      @compressed_size : Int64,
      @mime_type : String,
      @crc32 : UInt32,
      @storage_mode : StorageMode,
    )
      @volume_name = volume_name.to_s
    end

    # Opens a readable stream for this asset.
    abstract def open : IO

    # Yields an open stream to the block and automatically closes it upon completion.
    def open(&block : IO -> T) : T forall T
      stream = open
      begin
        yield stream
      ensure
        stream.close
      end
    end

    # Returns the full contents as a byte slice.
    abstract def to_slice : Bytes

    # Streams the content into the given output IO.
    abstract def to_s(io : IO) : Nil

    # Returns the content as a UTF-8 String.
    def to_s : String
      String.build(size.to_i32) do |str_io|
        to_s(str_io)
      end
    end

    # Alias for to_s for instant content inspection.
    def content : String
      to_s
    end

    # Hexadecimal formatted CRC32 checksum (e.g. "a1b2c3d4").
    def crc32_hex : String
      sprintf("%08x", @crc32)
    end

    # HTTP-compliant ETag string based on CRC32 checksum and file size.
    def etag : String
      "\"#{crc32_hex}-#{@size}\""
    end

    # Extracts this virtual file to a target path on disk.
    def extract(target_path : Path | String, overwrite : Bool = true) : Bool
      dest = Path.new(target_path.to_s)
      return false if File.exists?(dest) && !overwrite

      FileUtils.mkdir_p(dest.parent)
      File.open(dest, "wb") do |out_file|
        open do |in_stream|
          IO.copy(in_stream, out_file)
        end
      end
      true
    end
  end

  # Directly inlined static asset (Bake mode).
  # Holds a direct reference to static binary data in memory for instant, zero-copy reads.
  class BakedItem < Item
    getter data : Bytes

    def initialize(
      path : String,
      volume_name : Symbol | String,
      @data : Bytes,
      mime_type : String? = nil,
      crc32 : UInt32? = nil,
    )
      computed_mime = mime_type || MIME.from_path(path)
      computed_crc = crc32 || Digest::CRC32.checksum(@data)
      super(
        path: path,
        volume_name: volume_name,
        size: @data.size.to_i64,
        compressed_size: @data.size.to_i64,
        mime_type: computed_mime,
        crc32: computed_crc,
        storage_mode: StorageMode::Bake
      )
    end

    # Fast constructor from string literal
    def self.from_string(
      path : String,
      volume_name : Symbol | String,
      str : String,
      mime_type : String? = nil,
      crc32 : UInt32? = nil,
    ) : BakedItem
      new(path, volume_name, str.to_slice, mime_type, crc32)
    end

    def open : IO
      IO::Memory.new(@data, writable: false)
    end

    def to_slice : Bytes
      @data
    end

    def to_s(io : IO) : Nil
      io.write(@data)
    end

    def to_s : String
      String.new(@data)
    end
  end

  # Chunked, compressed, and stream-backed asset (Store mode).
  # Employs Bakelite::FileIO to stream chunks on demand in O(chunk_size) RAM.
  class StoredItem < Item
    getter chunks : Array(Chunk)
    getter compression : CompressionType
    getter underlying_io : IO?

    def initialize(
      path : String,
      volume_name : Symbol | String,
      size : Int64,
      compressed_size : Int64,
      @chunks : Array(Chunk),
      @compression : CompressionType = CompressionType::None,
      mime_type : String? = nil,
      crc32 : UInt32 = 0_u32,
      @underlying_io : IO? = nil,
    )
      computed_mime = mime_type || MIME.from_path(path)
      super(
        path: path,
        volume_name: volume_name,
        size: size,
        compressed_size: compressed_size,
        mime_type: computed_mime,
        crc32: crc32,
        storage_mode: StorageMode::Store
      )
    end

    def open : IO
      FileIO.new(
        chunks: @chunks,
        size: @size,
        compression: @compression,
        underlying_io: @underlying_io
      )
    end

    def to_slice : Bytes
      slice = Bytes.new(@size)
      open do |stream|
        stream.read_fully(slice)
      end
      slice
    end

    def to_s(io : IO) : Nil
      open do |stream|
        IO.copy(stream, io)
      end
    end
  end
end
