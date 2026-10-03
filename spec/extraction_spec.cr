require "./spec_helper"
require "file_utils"

module TestExtractionFS
  include Bakelite::FS

  volume :engine, mount: "engine" do
    bake "shard.yml", as_path: "core/shard.yml", volume: :engine
    bake "shard.yml", as_path: "src/engine.cr", volume: :engine
  end

  volume :template, mount: "template" do
    bake "shard.yml", as_path: "project.godot", volume: :template
    bake "shard.yml", as_path: "scenes/main.tscn", volume: :template
  end
end

describe "Bakelite: Volume Extraction API" do
  tmp_dir = File.join(Dir.tempdir, "bakelite_extraction_test_#{Time.utc.to_unix_ms}")

  before_all do
    FileUtils.mkdir_p(tmp_dir)
  end

  after_all do
    FileUtils.rm_rf(tmp_dir)
  end

  it "extracts an entire volume using extract_volume" do
    dest = File.join(tmp_dir, "engine_out")
    count = TestExtractionFS.extract_volume(:engine, dest)
    count.should eq(2)

    File.exists?(File.join(dest, "core", "shard.yml")).should be_true
    File.exists?(File.join(dest, "src", "engine.cr")).should be_true
  end

  it "extracts a subfolder from a volume using extract_volume_folder" do
    dest = File.join(tmp_dir, "template_scenes_out")
    count = TestExtractionFS.extract_volume_folder(:template, "scenes", dest)
    count.should eq(1)

    File.exists?(File.join(dest, "main.tscn")).should be_true
    File.exists?(File.join(dest, "project.godot")).should be_false
  end

  it "supports extraction on Registry instances directly" do
    reg = Bakelite::FS::Registry.new
    vol = Bakelite::Volume.new(:custom)
    vol.add(Bakelite::BakedItem.new("sub/test.txt", :custom, "custom content".to_slice, "text/plain", 0_u32))
    reg.mount(vol)

    dest = File.join(tmp_dir, "registry_vol_out")
    count = reg.extract_volume(:custom, dest)
    count.should eq(1)
    File.read(File.join(dest, "sub", "test.txt")).should eq("custom content")
  end

  it "returns 0 when attempting to extract a nonexistent volume" do
    dest = File.join(tmp_dir, "nonexistent")
    TestExtractionFS.extract_volume(:nonexistent, dest).should eq(0)
    TestExtractionFS.extract_volume_folder(:nonexistent, "prefix", dest).should eq(0)
  end
end
