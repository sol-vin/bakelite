require "./spec_helper"

describe "Bakelite: Custom Volumes & Union Routing" do
  it "manages isolated volumes with mount point routing" do
    reg = Bakelite::FS::Registry.new

    # 1. Base Volume (root mount: "")
    reg.root_volume.add(Bakelite::BakedItem.from_string("shard.yml", :root, "name: game"))

    # 2. UI Volume (mount: "ui")
    ui_vol = Bakelite::Volume.new(:ui, mount_point: "ui", priority: 1)
    ui_vol.add(Bakelite::BakedItem.from_string("login.html", :ui, "<h1>Login</h1>"))
    ui_vol.add(Bakelite::BakedItem.from_string("theme.css", :ui, "body { color: blue; }"))
    reg.mount(ui_vol)

    # 3. Audio Volume (mount: "audio")
    audio_vol = Bakelite::Volume.new(:audio, mount_point: "audio", priority: 1)
    audio_vol.add(Bakelite::BakedItem.from_string("sfx/click.wav", :audio, "CLICK"))
    reg.mount(audio_vol)

    # Direct volume lookups (no mount prefix)
    reg.volume(:ui)["login.html"].content.should eq("<h1>Login</h1>")
    reg.volume(:audio)["sfx/click.wav"].content.should eq("CLICK")
    reg.volume(:ui).size.should eq(2)
    reg.volume(:audio).size.should eq(1)

    # Union router lookups (routes via mount prefix)
    reg["shard.yml"].content.should eq("name: game")
    reg["ui/login.html"].content.should eq("<h1>Login</h1>")
    reg["ui/theme.css"].content.should eq("body { color: blue; }")
    reg["audio/sfx/click.wav"].content.should eq("CLICK")

    # Safe lookup returns nil for missing files
    reg["ui/missing.png"]?.should be_nil
    reg.has_file?("ui/login.html").should be_true
    reg.has_file?("non_existent").should be_false

    # Total union files
    reg.files.should eq(["audio/sfx/click.wav", "shard.yml", "ui/login.html", "ui/theme.css"])
  end

  it "implements priority shadowing and dynamic unmounting (Mod / DLC pattern)" do
    reg = Bakelite::FS::Registry.new

    # Base game texture in root volume (priority 0)
    base_item = Bakelite::BakedItem.from_string("textures/hero.png", :root, "BASE_HERO_SPRITE")
    reg.root_volume.add(base_item)

    reg["textures/hero.png"].content.should eq("BASE_HERO_SPRITE")

    # Mount a community HD mod volume with priority 10 at root mount
    mod_vol = Bakelite::Volume.new(:mod_hd, mount_point: "", priority: 10)
    mod_item = Bakelite::BakedItem.from_string("textures/hero.png", :mod_hd, "HD_HERO_SPRITE_4K")
    mod_vol.add(mod_item)
    reg.mount(mod_vol)

    # Query now transparently returns HD texture because mod has higher priority!
    active_item = reg["textures/hero.png"]
    active_item.content.should eq("HD_HERO_SPRITE_4K")
    active_item.volume_name.should eq("mod_hd")

    # Unmount the mod
    reg.unmount(:mod_hd).should be_true

    # Query cleanly falls back to the original base game texture!
    fallback_item = reg["textures/hero.png"]
    fallback_item.content.should eq("BASE_HERO_SPRITE")
    fallback_item.volume_name.should eq("root")
  end

  it "supports globbing across volume boundaries" do
    reg = Bakelite::FS::Registry.new

    ui_vol = Bakelite::Volume.new(:ui, mount_point: "ui")
    ui_vol.add(Bakelite::BakedItem.from_string("views/home.html", :ui, "home"))
    ui_vol.add(Bakelite::BakedItem.from_string("views/profile.html", :ui, "profile"))
    ui_vol.add(Bakelite::BakedItem.from_string("css/style.css", :ui, "css"))
    reg.mount(ui_vol)

    matched = reg.glob("ui/views/*.html")
    matched.size.should eq(2)
    matched.map(&.path).sort.should eq(["views/home.html", "views/profile.html"])
  end
end
