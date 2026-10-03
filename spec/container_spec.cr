require "./spec_helper"

describe "Bakelite: Post-Compile Container & Appended Overlay" do
  it "packs files into a standalone .bkl container and reads them back" do
    temp_work = BakeliteSpecHelper.temp_dir
    source_dir = temp_work.join("source_assets")
    container_path = temp_work.join("test_volume.bkl")
    dest_dir = temp_work.join("extracted_assets")

    begin
      # 1. Create source fixture files
      FileUtils.mkdir_p(source_dir.join("ui"))
      FileUtils.mkdir_p(source_dir.join("audio"))
      File.write(source_dir.join("ui/theme.json"), "{\"theme\":\"dark\"}")
      File.write(source_dir.join("ui/index.html"), "<h1>Bakelite</h1>")
      BakeliteSpecHelper.generate_synthetic_file(source_dir.join("audio/ping.wav"), 100_000)

      # 2. Pack into .bkl container
      writer = Bakelite::Container::Writer.new(container_path)
      writer.pack_directory(
        source_dir: source_dir,
        volume_name: :assets,
        mount_point: "assets",
        chunk_size: 16384_u32,
        compression: Bakelite::CompressionType::Deflate
      )
      payload_size = writer.write(append: false)
      payload_size.should be > 0
      File.exists?(container_path).should be_true

      # 3. Validate trailer detection
      Bakelite::Container::Reader.has_trailer?(container_path).should be_true

      # 4. Read back through Reader
      reader = Bakelite::Container::Reader.new(container_path)
      volumes = reader.read
      volumes.size.should eq(1)

      vol = volumes.first
      vol.name.should eq("assets")
      vol.mount_point.should eq("assets")
      vol.has_file?("ui/theme.json").should be_true
      vol.has_file?("ui/index.html").should be_true
      vol.has_file?("audio/ping.wav").should be_true

      # Verify content integrity
      vol["ui/theme.json"].content.should eq("{\"theme\":\"dark\"}")
      vol["ui/index.html"].content.should eq("<h1>Bakelite</h1>")
      vol["audio/ping.wav"].size.should eq(100_000)

      # 5. Extract to disk and verify
      vol.extract(dest_dir)
      File.read(dest_dir.join("ui/theme.json")).should eq("{\"theme\":\"dark\"}")
      File.size(dest_dir.join("audio/ping.wav")).should eq(100_000)
    ensure
      BakeliteSpecHelper.cleanup(temp_work)
    end
  end

  it "appends a Bakelite volume to an existing binary image (overlay pattern)" do
    temp_work = BakeliteSpecHelper.temp_dir
    fake_exe = temp_work.join("game.exe")
    source_dir = temp_work.join("overlay_data")

    begin
      # 1. Create a dummy executable (500KB of random host binary bytes)
      fake_exe_bytes = BakeliteSpecHelper.generate_synthetic_file(fake_exe, 500_000)
      initial_exe_size = File.size(fake_exe)
      initial_exe_size.should eq(500_000)

      # Before appending, it should NOT have a trailer
      Bakelite::Container::Reader.has_trailer?(fake_exe).should be_false

      # 2. Create overlay source files
      FileUtils.mkdir_p(source_dir)
      File.write(source_dir.join("level1.json"), "{\"map\":\"desert_oasis\"}")
      File.write(source_dir.join("config.cfg"), "difficulty=hard")

      # 3. Append volume to the fake executable
      writer = Bakelite::Container::Writer.new(fake_exe)
      writer.pack_directory(
        source_dir: source_dir,
        volume_name: :dlc,
        mount_point: "dlc",
        priority: 5,
        compression: Bakelite::CompressionType::Deflate
      )
      written_bytes = writer.write(append: true)
      written_bytes.should be > 0

      # Host binary size must now be initial size + appended volume!
      new_exe_size = File.size(fake_exe)
      new_exe_size.should be > initial_exe_size

      # Verify host binary bytes at the start are 100% UNTOUCHED
      head_bytes = Bytes.new(500_000)
      File.open(fake_exe, "rb") { |f| f.read_fully(head_bytes) }
      head_bytes.should eq(fake_exe_bytes)

      # 4. Now trailer detection succeeds!
      Bakelite::Container::Reader.has_trailer?(fake_exe).should be_true

      # 5. Mount the appended executable into a virtual filesystem
      reg = Bakelite::FS::Registry.new
      mounted_vol = reg.mount_file(fake_exe)
      mounted_vol.should_not be_nil

      # Query via union router
      reg["dlc/level1.json"].content.should eq("{\"map\":\"desert_oasis\"}")
      reg["dlc/config.cfg"].content.should eq("difficulty=hard")
    ensure
      BakeliteSpecHelper.cleanup(temp_work)
    end
  end
end
