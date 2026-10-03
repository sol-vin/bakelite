require "./spec_helper"

describe "Bakelite: Large File Breaking, Chunking & Streaming" do
  it "partitions a large 2MB file into 64KB chunks with exact integrity" do
    total_size = 2 * 1024 * 1024   # 2 Megabytes
    chunk_size = 64_u32 * 1024_u32 # 64 KB

    # Generate synthetic binary payload with non-trivial byte patterns
    raw_buffer = Bytes.new(total_size)
    total_size.times do |i|
      raw_buffer[i] = ((i.to_i64 * 41_i64 + 17_i64) ^ (i >> 8)).to_u8!
    end
    original_crc32 = Digest::CRC32.checksum(raw_buffer)

    # 1. Chunk the data
    chunks = Bakelite::Chunker.chunk_data(
      data: raw_buffer,
      chunk_size: chunk_size,
      compression: Bakelite::CompressionType::Deflate
    )

    expected_chunks = (total_size / chunk_size).to_i
    chunks.size.should eq(expected_chunks)

    # 2. Verify chunk invariants
    running_uncompressed = 0_i64
    chunks.each_with_index do |chunk, idx|
      chunk.uncompressed_size.should eq(chunk_size)
      chunk.compressed_size.should be > 0
      chunk.compressed_size.should be <= chunk_size * 2 # Deflate bound

      # Verify individual chunk CRC32 matches source slice
      slice = raw_buffer[running_uncompressed, chunk.uncompressed_size.to_i32]
      chunk.crc32.should eq(Digest::CRC32.checksum(slice))

      running_uncompressed += chunk.uncompressed_size
    end
    running_uncompressed.should eq(total_size.to_i64)

    # 3. Stream back via FileIO and assert byte-for-byte identity
    stored_item = Bakelite::StoredItem.new(
      path: "large_asset.dat",
      volume_name: :test,
      size: total_size.to_i64,
      compressed_size: chunks.sum(&.compressed_size.to_i64),
      chunks: chunks,
      compression: Bakelite::CompressionType::Deflate,
      crc32: original_crc32
    )

    reconstructed = Bytes.new(total_size)
    stored_item.open do |stream|
      stream.read_fully(reconstructed)
    end

    reconstructed.should eq(raw_buffer)
    Digest::CRC32.checksum(reconstructed).should eq(original_crc32)
  end

  it "supports seeking across arbitrary chunk boundaries in a large file" do
    total_size = 1024 * 1024       # 1 MB
    chunk_size = 32_u32 * 1024_u32 # 32 KB (32 chunks)

    raw_buffer = Bytes.new(total_size)
    total_size.times do |i|
      raw_buffer[i] = ((i * 19 + 7) % 251).to_u8
    end

    chunks = Bakelite::Chunker.chunk_data(
      data: raw_buffer,
      chunk_size: chunk_size,
      compression: Bakelite::CompressionType::Deflate
    )

    stored_item = Bakelite::StoredItem.new(
      path: "seek_test.bin",
      volume_name: :test,
      size: total_size.to_i64,
      compressed_size: chunks.sum(&.compressed_size.to_i64),
      chunks: chunks,
      compression: Bakelite::CompressionType::Deflate,
      crc32: Digest::CRC32.checksum(raw_buffer)
    )

    stored_item.open do |stream|
      # Seek into chunk 15 (offset 500,000)
      target_pos = 500_000_i64
      stream.seek(target_pos, IO::Seek::Set)
      stream.pos.should eq(target_pos)

      buf = Bytes.new(100)
      stream.read_fully(buf)
      buf.should eq(raw_buffer[target_pos, 100])

      # Seek backward into chunk 2 (offset 70,000)
      back_pos = 70_000_i64
      stream.seek(back_pos, IO::Seek::Set)
      stream.pos.should eq(back_pos)

      buf2 = Bytes.new(256)
      stream.read_fully(buf2)
      buf2.should eq(raw_buffer[back_pos, 256])

      # Seek relative to current position
      stream.seek(10_000_i64, IO::Seek::Current)
      stream.pos.should eq(back_pos + 256 + 10_000)

      # Seek from end
      stream.seek(-50_i64, IO::Seek::End)
      stream.pos.should eq(total_size - 50)
      tail_buf = Bytes.new(50)
      stream.read_fully(tail_buf)
      tail_buf.should eq(raw_buffer[total_size - 50, 50])
    end
  end

  it "reads across chunk boundaries in a single read call" do
    total_size = 128 * 1024        # 128 KB
    chunk_size = 16_u32 * 1024_u32 # 16 KB chunks

    raw_buffer = Bytes.new(total_size)
    total_size.times do |i|
      raw_buffer[i] = (i % 256).to_u8
    end

    chunks = Bakelite::Chunker.chunk_data(
      data: raw_buffer,
      chunk_size: chunk_size,
      compression: Bakelite::CompressionType::Deflate
    )

    stored_item = Bakelite::StoredItem.new(
      path: "boundary_test.bin",
      volume_name: :test,
      size: total_size.to_i64,
      compressed_size: chunks.sum(&.compressed_size.to_i64),
      chunks: chunks,
      compression: Bakelite::CompressionType::Deflate,
      crc32: Digest::CRC32.checksum(raw_buffer)
    )

    stored_item.open do |stream|
      # Position at 15 KB (1 KB before chunk 0 ends)
      stream.seek(15 * 1024, IO::Seek::Set)

      # Read 4 KB (spans 1 KB of chunk 0 and 3 KB of chunk 1)
      read_buf = Bytes.new(4 * 1024)
      bytes_read = stream.read_fully(read_buf)
      bytes_read.should eq(4 * 1024)
      read_buf.should eq(raw_buffer[15 * 1024, 4 * 1024])
    end
  end
end
