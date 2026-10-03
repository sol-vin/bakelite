require "./spec_helper"

# High-throughput deterministic synthetic stream generator for scale testing.
# Generates structured chunks with unique headers and footers using O(1) memory.
class SyntheticPatternIO < IO
  getter size : Int64
  getter pos : Int64 = 0_i64
  getter chunk_size : Int32

  def initialize(@size : Int64, @chunk_size : Int32 = 65536)
  end

  def read(slice : Bytes) : Int32
    return 0 if @pos >= @size || slice.empty?
    to_read = Math.min(slice.size.to_i64, @size - @pos).to_i32

    bytes_written = 0
    while bytes_written < to_read
      curr_abs = @pos + bytes_written
      chunk_idx = (curr_abs // @chunk_size).to_i32
      offset_in_chunk = (curr_abs % @chunk_size).to_i32

      byte_val = if offset_in_chunk < 32
                   header_str = sprintf("CHK_%08d_OFF_%014d\n", chunk_idx, (chunk_idx.to_i64 * @chunk_size))
                   header_str.to_slice[offset_in_chunk]
                 elsif offset_in_chunk >= (@chunk_size - 16)
                   footer_str = sprintf("\nEND_%08d\n\n\n\n\n", chunk_idx)
                   idx_in_footer = offset_in_chunk - (@chunk_size - 16)
                   footer_str.to_slice[idx_in_footer]
                 else
                   ((offset_in_chunk % 26) + 65).to_u8
                 end

      slice[bytes_written] = byte_val
      bytes_written += 1
    end

    @pos += to_read
    to_read
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("SyntheticPatternIO is read-only")
  end

  def seek(offset : Int, whence : IO::Seek = IO::Seek::Set) : self
    target = case whence
             when IO::Seek::Set     then offset.to_i64
             when IO::Seek::Current then @pos + offset.to_i64
             when IO::Seek::End     then @size + offset.to_i64
             else
               raise ArgumentError.new("Invalid whence: #{whence}")
             end
    raise ArgumentError.new("Negative seek: #{target}") if target < 0
    @pos = target
    self
  end
end

describe "Bakelite: Large Scale Fake Data Tests (100MB & 1GB)" do
  it "packs, streams, seeks, and verifies a 100MB file on disk" do
    temp_dir = BakeliteSpecHelper.temp_dir
    file_100mb = temp_dir.join("data_100mb.bin")
    container_100mb = temp_dir.join("scale_100mb.bkl")
    size_100mb = 100_i64 * 1024 * 1024 # 104,857,600 bytes (1,600 chunks at 64KB)

    begin
      # 1. Generate real 100MB file on disk from synthetic pattern
      File.open(file_100mb, "wb") do |f|
        IO.copy(SyntheticPatternIO.new(size_100mb), f)
      end
      File.size(file_100mb).should eq(size_100mb)

      # 2. Pack 100MB file into container using streaming writer
      writer = Bakelite::Container::Writer.new(container_100mb)
      File.open(file_100mb, "rb") do |raw_in|
        writer.pack_stream(raw_in, size: size_100mb, virtual_path: "assets/big_video.mp4", chunk_size: 65536)
      end
      writer.write(append: false)
      File.exists?(container_100mb).should be_true

      # Container size should be compact due to Deflate
      File.size(container_100mb).should be < (1_i64 * 1024 * 1024)

      # 3. Read through Container::Reader
      reader = Bakelite::Container::Reader.new(container_100mb)
      volumes = reader.read
      volumes.size.should be >= 1

      item = volumes.first["assets/big_video.mp4"]
      item.size.should eq(size_100mb)
      item.is_a?(Bakelite::StoredItem).should be_true

      stored = item.as(Bakelite::StoredItem)
      stored.chunks.size.should eq(1600)

      # 4. Stream and Seek Tests across 100MB range
      stored.open do |io|
        # Read initial chunk header at 0MB
        buf = Bytes.new(32)
        io.read_fully(buf)
        String.new(buf).should start_with("CHK_00000000")

        # Seek to 25MB (chunk #400)
        pos_25mb = 400_i64 * 65536
        io.seek(pos_25mb)
        io.read_fully(buf)
        String.new(buf).should start_with("CHK_00000400")

        # Seek to 50MB (chunk #800)
        pos_50mb = 800_i64 * 65536
        io.seek(pos_50mb)
        io.read_fully(buf)
        String.new(buf).should start_with("CHK_00000800")

        # Multi-chunk span read across 128KB (2 chunks)
        multi_buf = Bytes.new(131072)
        io.seek(pos_50mb)
        io.read_fully(multi_buf)
        io.pos.should eq(pos_50mb + 131072)

        # Seek near EOF (last 16 bytes of chunk #1599)
        io.seek(size_100mb - 16)
        footer_buf = Bytes.new(16)
        io.read_fully(footer_buf)
        String.new(footer_buf).should contain("END_00001599")
      end
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end

  it "packs, streams, seeks, and verifies a 1GB file with 64-bit offsets" do
    temp_dir = BakeliteSpecHelper.temp_dir
    container_1gb = temp_dir.join("scale_1gb.bkl")
    size_1gb = 1024_i64 * 1024 * 1024 # 1,073,741,824 bytes (16,384 chunks at 64KB)

    begin
      # Pack 1GB synthetic stream into .bkl container
      writer = Bakelite::Container::Writer.new(container_1gb)
      synthetic_io = SyntheticPatternIO.new(size_1gb)
      writer.pack_stream(synthetic_io, size: size_1gb, virtual_path: "world/huge_terrain.raw", chunk_size: 65536)
      writer.write(append: false)

      File.exists?(container_1gb).should be_true

      # Verify container reading and 64-bit metadata
      reader = Bakelite::Container::Reader.new(container_1gb)
      volumes = reader.read
      item = volumes.first["world/huge_terrain.raw"]
      item.size.should eq(size_1gb)

      stored = item.as(Bakelite::StoredItem)
      stored.chunks.size.should eq(16384)

      # Verify 32-byte trailer at end of file
      trailer = reader.trailer
      trailer.should_not be_nil
      if t = trailer
        t.magic.should eq(Bakelite::Container::MAGIC_TRAILER)
      end

      # Deep seeks across 1GB range
      stored.open do |io|
        buf = Bytes.new(32)

        # Byte 0
        io.seek(0)
        io.read_fully(buf)
        String.new(buf).should start_with("CHK_00000000")

        # Seek to 512MB (chunk #8192)
        pos_512mb = 8192_i64 * 65536 # 536,870,912 bytes
        io.seek(pos_512mb)
        io.read_fully(buf)
        String.new(buf).should start_with("CHK_00008192")

        # Seek to 768MB (chunk #12288)
        pos_768mb = 12288_i64 * 65536 # 805,306,368 bytes
        io.seek(pos_768mb)
        io.read_fully(buf)
        String.new(buf).should start_with("CHK_00012288")

        # Seek to 1GB - 16 bytes (final chunk #16383 footer)
        io.seek(size_1gb - 16)
        footer_buf = Bytes.new(16)
        io.read_fully(footer_buf)
        String.new(footer_buf).should contain("END_00016383")
      end
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end
end
