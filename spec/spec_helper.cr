require "spec"
require "file_utils"
require "path"
require "../src/bakelite"

# Test fixtures and temporary directories helper
module BakeliteSpecHelper
  def self.temp_dir : Path
    dir = Path.new(Dir.tempdir).join("bakelite_spec_#{Time.utc.to_unix_ns}_#{rand(1000..9999)}")
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.cleanup(dir : Path)
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end

  # Generates a synthetic binary file with deterministic pseudo-random bytes
  def self.generate_synthetic_file(path : Path | String, size_in_bytes : Int32) : Bytes
    dest = Path.new(path.to_s)
    FileUtils.mkdir_p(dest.parent)

    buffer = Bytes.new(size_in_bytes)
    size_in_bytes.times do |i|
      buffer[i] = ((i * 37 + 13) % 256).to_u8
    end

    File.write(dest, buffer)
    buffer
  end
end
