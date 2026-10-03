module Bakelite
  # Represents how an asset is stored in the binary or volume.
  enum StorageMode : UInt8
    # Inlined directly into compiled binary as static String/Bytes.
    # Instant, zero-copy access; best for configs, manifests, small templates.
    Bake = 0_u8

    # Chunked, compressed, and stream-backed.
    # Reads through Bakelite::FileIO in O(chunk_size) RAM; best for media, large files.
    Store = 1_u8
  end

  # Supported compression algorithms for stored chunks.
  enum CompressionType : UInt8
    None    = 0_u8
    Deflate = 1_u8
    Gzip    = 2_u8
    Zlib    = 3_u8

    def self.parse(val : Symbol | String) : CompressionType
      case val.to_s.downcase.lchop(':')
      when "deflate"     then Deflate
      when "gzip"        then Gzip
      when "zlib"        then Zlib
      when "none", "raw" then None
      else
        raise ArgumentError.new("Unsupported compression type '#{val}'. Supported: deflate, gzip, zlib, none")
      end
    end

    def self.from_symbol(sym : Symbol | String) : CompressionType
      parse(sym)
    end
  end

  # Represents a single chunk of a stored file.
  struct Chunk
    getter offset : Int64
    getter compressed_size : UInt32
    getter uncompressed_size : UInt32
    getter crc32 : UInt32
    getter data : Bytes?

    def initialize(
      @offset : Int64,
      @compressed_size : UInt32,
      @uncompressed_size : UInt32,
      @crc32 : UInt32,
      @data : Bytes? = nil,
    )
    end
  end

  # Metadata describing an embedded or stored file.
  struct FileMetadata
    getter path : String
    getter volume_name : String
    getter size : Int64
    getter compressed_size : Int64
    getter mode : StorageMode
    getter compression : CompressionType
    getter mime_type : String
    getter crc32 : UInt32
    getter chunk_size : UInt32
    getter chunks : Array(Chunk)

    def initialize(
      @path : String,
      volume_name : Symbol | String,
      @size : Int64,
      @compressed_size : Int64,
      @mode : StorageMode,
      @compression : CompressionType,
      @mime_type : String,
      @crc32 : UInt32,
      @chunk_size : UInt32 = 65536_u32,
      @chunks : Array(Chunk) = [] of Chunk,
    )
      @volume_name = volume_name.to_s
    end
  end

  # Base exception for all Bakelite-specific errors.
  class Error < Exception
  end

  # Raised when attempting to parse or access a corrupted container.
  class CorruptContainerError < Error
  end

  # Raised when the 32-byte trailer at the end of a container is missing or invalid.
  class InvalidTrailerError < Error
  end

  # Raised when a CRC32 verification fails.
  class ChecksumMismatchError < Error
  end
end
