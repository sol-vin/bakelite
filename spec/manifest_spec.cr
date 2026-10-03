require "./spec_helper"

module TestManifestApp
  include Bakelite::FS

  # Declarative multi-volume manifest baking in a single compile-time pass
  bake_manifest "spec/fixtures/manifest.yml", base_dir: "spec/fixtures/test_project"
end

describe "Bakelite: Declarative Multi-Volume Manifest DSL (bake_manifest)" do
  it "creates and mounts all volumes defined in the manifest" do
    TestManifestApp.fs.volume?(:engine).should_not be_nil
    TestManifestApp.fs.volume?(:template).should_not be_nil
    TestManifestApp.fs.volume?(:addon).should_not be_nil
  end

  it "bakes engine files with auto_threshold < 16KB" do
    item = TestManifestApp["shard.yml"]
    item.should_not be_nil
    item.storage_mode.should eq(Bakelite::StorageMode::Bake)
    item.volume_name.should eq("engine")
    item.content.should contain("name: test_project")

    bridge = TestManifestApp["src/bridge/crystal_bridge.cpp"]
    bridge.should_not be_nil
    bridge.volume_name.should eq("engine")
  end

  it "properly applies exclusions and negative globs" do
    # src/main.cr was in exclude list
    TestManifestApp.fs.has_file?("src/main.cr").should be_false
    TestManifestApp.fs.volume(:engine).has_file?("src/main.cr").should be_false

    # src/libgodot/docs/** was in exclude list
    TestManifestApp.fs.has_file?("src/libgodot/docs/guide.md").should be_false

    # **/*.uid was in exclude list
    TestManifestApp.fs.has_file?("scenes/main.tscn.uid").should be_false
  end

  it "routes template volume through union mount 'template'" do
    # Direct access in volume
    tmpl_item = TestManifestApp.fs.volume(:template)["project.godot"]
    tmpl_item.should_not be_nil
    tmpl_item.content.should contain("config_version=5")

    # Union route access
    union_item = TestManifestApp["template/project.godot"]
    union_item.should_not be_nil
    union_item.content.should contain("config_version=5")

    # Subfolder inside template
    TestManifestApp.fs.has_file?("template/scenes/level.tscn").should be_true
  end

  it "routes addon volume through union mount 'addons/crystal_integration'" do
    addon_item = TestManifestApp["addons/crystal_integration/crystal_integration.gd"]
    addon_item.should_not be_nil
    addon_item.content.should contain("EditorPlugin")
  end

  it "extracts lean :engine volume cleanly" do
    dest = File.join(Dir.tempdir, "bakelite_manifest_extract_#{Time.utc.to_unix_ms}")
    begin
      count = TestManifestApp.extract_volume(:engine, dest)
      count.should be >= 4

      File.exists?(File.join(dest, "shard.yml")).should be_true
      File.exists?(File.join(dest, "src", "libgodot.cr")).should be_true
      File.exists?(File.join(dest, "src", "main.cr")).should be_false
      File.exists?(File.join(dest, "src", "libgodot", "docs", "guide.md")).should be_false
    ensure
      FileUtils.rm_rf(dest)
    end
  end
end
