require "./spec_helper"

describe "Bakelite: Streaming FileIO Compliance" do
  it "supports small slice chunking and IO.copy piping" do
    text = (1..500).map { |i| "Line #{i}: The quick brown fox jumps over the lazy dog." }.join("\n")
    bytes = text.to_slice
    chunks = Bakelite::Chunker.chunk_data(bytes, chunk_size: 256_u32, compression: Bakelite::CompressionType::Deflate)

    item = Bakelite::StoredItem.new(
      path: "lines.txt",
      volume_name: :test,
      size: bytes.size.to_i64,
      compressed_size: chunks.sum(&.compressed_size.to_i64),
      chunks: chunks,
      compression: Bakelite::CompressionType::Deflate
    )

    # 1. Pipe through IO.copy into IO::Memory
    dest_mem = IO::Memory.new
    item.open do |stream|
      IO.copy(stream, dest_mem)
    end
    dest_mem.to_s.should eq(text)

    # 2. Line-by-line reading with gets
    lines_read = [] of String
    item.open do |stream|
      while line = stream.gets
        lines_read << line
      end
    end
    lines_read.size.should eq(500)
    lines_read.first.should eq("Line 1: The quick brown fox jumps over the lazy dog.")
    lines_read.last.should eq("Line 500: The quick brown fox jumps over the lazy dog.")

    # 3. Read in tiny 3-byte chunks
    item.open do |stream|
      accumulated = IO::Memory.new
      tiny_buf = Bytes.new(3)
      while (n = stream.read(tiny_buf)) > 0
        accumulated.write(tiny_buf[0, n])
      end
      accumulated.to_s.should eq(text)
    end

    # 4. Raises on write
    item.open do |stream|
      expect_raises(IO::Error, "read-only") do
        stream.write(Bytes[1, 2, 3])
      end
    end
  end
end
