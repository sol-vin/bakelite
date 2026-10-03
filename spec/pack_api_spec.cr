require "./spec_helper"
require "file_utils"

describe "Bakelite: Programmatic Packaging API" do
  tmp_dir = File.join(Dir.tempdir, "bakelite_pack_api_test_#{Time.utc.to_unix_ms}")

  before_all do
    FileUtils.mkdir_p(tmp_dir)
  end

  after_all do
    FileUtils.rm_rf(tmp_dir)
  end

  it "packs a directory into a container file using Bakelite.pack" do
    src_dir = File.join(tmp_dir, "pack_source")
    FileUtils.mkdir_p(File.join(src_dir, "assets"))
    File.write(File.join(src_dir, "config.json"), %({"app": "demo"}))
    File.write(File.join(src_dir, "assets", "logo.txt"), "LOGO DATA")

    container_path = File.join(tmp_dir, "output.bkl")

    # Programmatic packing without spawning child processes
    written_bytes = Bakelite.pack(
      target: container_path,
      source_dir: src_dir,
      volume: :app_data,
      mount_point: "app",
      chunk_size: 1024_u32,
      compression: Bakelite::CompressionType::Deflate
    )

    written_bytes.should be > 0
    File.exists?(container_path).should be_true

    # Mount and verify contents through Bakelite::FS::Registry
    reg = Bakelite::FS::Registry.new
    reg.mount_file(container_path, volume_name: :app_data, mount: "app")

    reg.has_file?("app/config.json").should be_true
    reg.has_file?("app/assets/logo.txt").should be_true
    reg["app/config.json"].content.should eq(%({"app": "demo"}))
    reg["app/assets/logo.txt"].content.should eq("LOGO DATA")
  end

  it "packs preconfigured volumes using Bakelite.pack(target, volumes)" do
    vol1 = Bakelite::Volume.new(:core, mount_point: "core")
    vol1.add(Bakelite::BakedItem.new("version.txt", :core, "1.0.0".to_slice, "text/plain", 0_u32))

    vol2 = Bakelite::Volume.new(:media, mount_point: "media")
    vol2.add(Bakelite::BakedItem.new("theme.css", :media, "body { color: blue; }".to_slice, "text/css", 0_u32))

    container_path = File.join(tmp_dir, "multi_vol.bkl")

    written_bytes = Bakelite.pack(
      target: container_path,
      volumes: [vol1, vol2]
    )

    written_bytes.should be > 0

    reg = Bakelite::FS::Registry.new
    reg.mount_file(container_path)

    reg.has_file?("core/version.txt").should be_true
    reg.has_file?("media/theme.css").should be_true
    reg["core/version.txt"].content.should eq("1.0.0")
    reg["media/theme.css"].content.should eq("body { color: blue; }")
  end
end
