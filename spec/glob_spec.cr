require "./spec_helper"

describe "Bakelite::Glob" do
  it "matches exact paths" do
    Bakelite::Glob.match?("src/libgodot.cr", ["src/libgodot.cr"]).should be_true
    Bakelite::Glob.match?("src/lapis.cr", ["src/libgodot.cr"]).should be_false
  end

  it "matches recursive wildcards" do
    Bakelite::Glob.match?("src/libgodot/sub/node.cr", ["src/libgodot/**/*.cr"]).should be_true
    Bakelite::Glob.match?("src/libgodot/node.cr", ["src/libgodot/**/*.cr"]).should be_true
    Bakelite::Glob.match?("src/bridge/crystal_bridge.cpp", ["src/bridge/**/*"]).should be_true
    Bakelite::Glob.match?("src/main.cr", ["src/libgodot/**/*.cr"]).should be_false
  end

  it "matches extension wildcards" do
    Bakelite::Glob.match?("scenes/main.tscn.uid", ["**/*.uid"]).should be_true
    Bakelite::Glob.match?("scenes/main.tscn", ["**/*.uid"]).should be_false
    Bakelite::Glob.match?("test.uid", ["*.uid"]).should be_true
    Bakelite::Glob.match?("sub/test.uid", ["*.uid"]).should be_true
  end

  it "supports negative patterns in includes list (!pattern)" do
    patterns = ["src/**/*.cr", "!src/main.cr", "!src/docs/**"]
    Bakelite::Glob.match?("src/libgodot.cr", patterns).should be_true
    Bakelite::Glob.match?("src/main.cr", patterns).should be_false
    Bakelite::Glob.match?("src/docs/guide.md", patterns).should be_false
  end

  it "supports explicit exclude list" do
    patterns = ["src/**/*"]
    excludes = ["src/main.cr", "src/docs/**", "**/*.uid"]

    Bakelite::Glob.match?("src/libgodot.cr", patterns, excludes).should be_true
    Bakelite::Glob.match?("src/main.cr", patterns, excludes).should be_false
    Bakelite::Glob.match?("src/docs/chapter1.md", patterns, excludes).should be_false
    Bakelite::Glob.match?("src/asset.uid", patterns, excludes).should be_false
  end
end
