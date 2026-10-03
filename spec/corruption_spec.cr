require "./spec_helper"

describe "Bakelite: Corruption and Error Handling" do
  it "raises InvalidTrailerError when container file is smaller than 32 bytes" do
    temp_dir = BakeliteSpecHelper.temp_dir
    tiny_file = temp_dir.join("tiny.bkl")

    begin
      File.write(tiny_file, "Too small")
      reader = Bakelite::Container::Reader.new(tiny_file)

      expect_raises(Bakelite::InvalidTrailerError) do
        reader.read
      end
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end

  it "raises InvalidTrailerError when 32-byte trailer magic is invalid" do
    temp_dir = BakeliteSpecHelper.temp_dir
    bad_trailer = temp_dir.join("bad_trailer.bkl")

    begin
      # 32 bytes of garbage without MAGIC_TRAILER
      File.write(bad_trailer, Bytes.new(64, 0x42_u8))
      reader = Bakelite::Container::Reader.new(bad_trailer)

      expect_raises(Bakelite::InvalidTrailerError) do
        reader.read
      end
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end

  it "raises CorruptContainerError when volume header magic is invalid" do
    temp_dir = BakeliteSpecHelper.temp_dir
    src_data = temp_dir.join("src_corr")
    container = temp_dir.join("tampered.bkl")

    begin
      FileUtils.mkdir_p(src_data)
      File.write(src_data.join("sample.txt"), "Hello World")

      writer = Bakelite::Container::Writer.new(container)
      writer.pack_directory(src_data)
      writer.write(append: false)

      # Tamper with the volume header (first 8 bytes)
      bytes = File.read(container).to_slice.dup
      8.times { |i| bytes[i] = 0xFF_u8 }
      File.write(container, bytes)

      reader = Bakelite::Container::Reader.new(container)
      expect_raises(Bakelite::CorruptContainerError) do
        reader.read
      end
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end
end
