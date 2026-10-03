require "./spec_helper"

describe "Bakelite: CLI Tool Commands" do
  cli_exe = Path.new("bin/bakelite.exe").expand

  it "packs, inspects, lists, verifies, and extracts via CLI" do
    temp_dir = BakeliteSpecHelper.temp_dir
    src_data = temp_dir.join("cli_src")
    container = temp_dir.join("bundle.bkl")
    extract_target = temp_dir.join("cli_dest")

    begin
      FileUtils.mkdir_p(src_data)
      File.write(src_data.join("sample.txt"), "Hello from CLI test!")
      File.write(src_data.join("config.yml"), "mode: test\nactive: true")

      # 1. Test `bakelite pack`
      pack_status = Process.run(
        cli_exe.to_s,
        ["pack", container.to_s, src_data.to_s, "--volume", "myvol", "--mount", "myvol"],
        shell: false
      )
      pack_status.success?.should be_true
      File.exists?(container).should be_true

      # 2. Test `bakelite inspect`
      inspect_out = IO::Memory.new
      inspect_status = Process.run(
        cli_exe.to_s,
        ["inspect", container.to_s],
        output: inspect_out
      )
      inspect_status.success?.should be_true
      inspect_out.to_s.should contain("BKLEND (Valid)")
      inspect_out.to_s.should contain("Volume :myvol")

      # 3. Test `bakelite list`
      list_out = IO::Memory.new
      list_status = Process.run(
        cli_exe.to_s,
        ["list", container.to_s],
        output: list_out
      )
      list_status.success?.should be_true
      list_out.to_s.should contain("sample.txt")
      list_out.to_s.should contain("config.yml")

      # 4. Test `bakelite verify`
      verify_out = IO::Memory.new
      verify_status = Process.run(
        cli_exe.to_s,
        ["verify", container.to_s],
        output: verify_out
      )
      verify_status.success?.should be_true
      verify_out.to_s.should contain("verified successfully")

      # 5. Test `bakelite extract`
      extract_status = Process.run(
        cli_exe.to_s,
        ["extract", container.to_s, extract_target.to_s],
        shell: false
      )
      extract_status.success?.should be_true
      File.exists?(extract_target.join("sample.txt")).should be_true
      File.read(extract_target.join("sample.txt")).should eq("Hello from CLI test!")
      File.read(extract_target.join("config.yml")).should eq("mode: test\nactive: true")
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end
end
