require "io/byte_format"

module Bakelite
  module Container
    MAGIC_HEADER   = "BAKELITE" # 8 bytes
    MAGIC_TRAILER  = "BKLEND"   # 6 bytes
    FORMAT_VERSION =  1_u16
    TRAILER_SIZE   = 32_i64

    BYTE_FORMAT = IO::ByteFormat::LittleEndian

    # Trailer structure located in the final 32 bytes of the container/executable.
    struct Trailer
      getter volume_start_offset : UInt64 # 8 bytes
      getter index_offset : UInt64        # 8 bytes (relative to volume start)
      getter index_size : UInt64          # 8 bytes
      getter version : UInt16             # 2 bytes
      getter magic : String               # 6 bytes

      def initialize(
        @volume_start_offset : UInt64,
        @index_offset : UInt64,
        @index_size : UInt64,
        @version : UInt16 = FORMAT_VERSION,
        @magic : String = MAGIC_TRAILER,
      )
      end

      # Serializes the 32-byte trailer to an IO stream.
      def write(io : IO) : Nil
        io.write_bytes(@volume_start_offset, BYTE_FORMAT)
        io.write_bytes(@index_offset, BYTE_FORMAT)
        io.write_bytes(@index_size, BYTE_FORMAT)
        io.write_bytes(@version, BYTE_FORMAT)

        magic_bytes = Bytes.new(6)
        @magic.to_slice[0, Math.min(6, @magic.bytesize)].copy_to(magic_bytes)
        io.write(magic_bytes)
      end

      # Reads and validates the 32-byte trailer from an IO stream.
      def self.read(io : IO) : Trailer?
        volume_start = io.read_bytes(UInt64, BYTE_FORMAT)
        index_offset = io.read_bytes(UInt64, BYTE_FORMAT)
        index_size = io.read_bytes(UInt64, BYTE_FORMAT)
        version = io.read_bytes(UInt16, BYTE_FORMAT)

        magic_buf = Bytes.new(6)
        io.read_fully(magic_buf)
        magic_str = String.new(magic_buf)

        return nil unless magic_str == MAGIC_TRAILER
        return nil unless version == FORMAT_VERSION

        new(
          volume_start_offset: volume_start,
          index_offset: index_offset,
          index_size: index_size,
          version: version,
          magic: magic_str
        )
      rescue
        nil
      end
    end
  end
end
