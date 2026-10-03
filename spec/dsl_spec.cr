require "./spec_helper"

module TestDSLApp
  include Bakelite::FS

  bake "shard.yml", as_path: "baked_shard.yml", volume: :config
  store "shard.yml", as_path: "stored_shard.yml", volume: :streamed, chunk_size: 128

  volume :ui, mount: "ui" do
    bake "shard.yml", as_path: "ui_shard.yml", volume: :ui
  end
end

describe "Bakelite: Compile-Time Macro DSL" do
  it "bakes files at compile time via macro DSL" do
    item = TestDSLApp["baked_shard.yml"]
    item.should_not be_nil
    item.storage_mode.should eq(Bakelite::StorageMode::Bake)
    item.content.should contain("name: bakelite")
    item.volume_name.should eq("config")
  end

  it "stores chunked files at compile time via macro DSL" do
    item = TestDSLApp["stored_shard.yml"]
    item.should_not be_nil
    item.storage_mode.should eq(Bakelite::StorageMode::Store)
    item.content.should contain("name: bakelite")
    item.volume_name.should eq("streamed")

    # Assert it was partitioned into chunks
    stored = item.as(Bakelite::StoredItem)
    stored.chunks.size.should be > 1
  end

  it "routes custom volume block declarations" do
    item = TestDSLApp["ui/ui_shard.yml"]
    item.should_not be_nil
    item.content.should contain("name: bakelite")
    item.volume_name.should eq("ui")

    vol_item = TestDSLApp.volume(:ui)["ui_shard.yml"]
    vol_item.content.should contain("name: bakelite")
  end
end
