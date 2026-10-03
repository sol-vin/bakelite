require "./spec_helper"

module TestBatchFolderApp
  include Bakelite::FS

  # Single-pass batch folder bake
  bake_folder "spec/fixtures/test_project/template", prefix: "baked_tmpl", volume: :tmpl_baked

  # Single-pass batch folder store with chunking and deflate compression
  store_folder "spec/fixtures/test_project/src", prefix: "stored_src", volume: :src_stored, chunk_size: 64, exclude: ["main.cr", "docs/**"]

  # Single-pass batch folder embed with auto threshold
  embed_folder "spec/fixtures/test_project/template", prefix: "auto_tmpl", volume: :tmpl_auto, threshold: 1024
end

describe "Bakelite: Single-Pass Batch Folder DSL" do
  it "bakes folder in single pass" do
    item = TestBatchFolderApp["baked_tmpl/project.godot"]
    item.should_not be_nil
    item.storage_mode.should eq(Bakelite::StorageMode::Bake)
    item.volume_name.should eq("tmpl_baked")
    item.content.should contain("config_version=5")
  end

  it "stores folder in single pass with exclusions applied" do
    item = TestBatchFolderApp["stored_src/libgodot.cr"]
    item.should_not be_nil
    item.storage_mode.should eq(Bakelite::StorageMode::Store)
    item.volume_name.should eq("src_stored")

    # Excluded files
    TestBatchFolderApp.fs.has_file?("stored_src/main.cr").should be_false
    TestBatchFolderApp.fs.has_file?("stored_src/libgodot/docs/guide.md").should be_false
  end

  it "embeds folder with auto threshold" do
    item = TestBatchFolderApp["auto_tmpl/scenes/level.tscn"]
    item.should_not be_nil
    # Size 21 bytes < 1024 threshold -> Bake
    item.storage_mode.should eq(Bakelite::StorageMode::Bake)
    item.volume_name.should eq("tmpl_auto")
  end
end
