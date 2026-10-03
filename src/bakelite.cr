require "./bakelite/version"
require "./bakelite/types"
require "./bakelite/mime"
require "./bakelite/file_io"
require "./bakelite/item"
require "./bakelite/volume"
require "./bakelite/container/format"
require "./bakelite/container/reader"
require "./bakelite/container/writer"
require "./bakelite/fs"
require "./bakelite/chunker"
require "./bakelite/glob"
require "./bakelite/transform/builtins"
require "./bakelite/transform/cache"
require "./bakelite/transform/runner"
require "./bakelite/dsl"

module Bakelite
  include Bakelite::FS
  include Bakelite::DSL

  @@global_fs : Bakelite::FS::Registry = Bakelite::FS::Registry.new

  # Top-level global filesystem registry
  def self.fs : Bakelite::FS::Registry
    @@global_fs
  end

  # Extracts an entire volume by name to destination directory.
  def self.extract_volume(name : Symbol | String, dest : Path | String, overwrite : Bool = true) : Int32
    fs.extract_volume(name, dest, overwrite: overwrite)
  end

  # Extracts a specific subfolder from a volume to destination directory.
  def self.extract_volume_folder(name : Symbol | String, prefix : String, dest : Path | String, overwrite : Bool = true) : Int32
    fs.extract_volume_folder(name, prefix, dest, overwrite: overwrite)
  end

  # Programmatic container packing API: packs a directory into a target container or appends to an executable.
  def self.pack(
    target : Path | String,
    source_dir : Path | String,
    volume : Symbol | String = :root,
    mount_point : String = "",
    priority : Int32 = 0,
    chunk_size : UInt32 = 65536_u32,
    compression : CompressionType = CompressionType::Deflate,
    exclude : Array(String) = [] of String,
    append : Bool = true,
  ) : Int64
    writer = Container::Writer.new(target)
    writer.pack_directory(
      source_dir: source_dir,
      volume_name: volume,
      mount_point: mount_point,
      priority: priority,
      chunk_size: chunk_size,
      compression: compression,
      exclude: exclude
    )
    writer.write(append: append)
  end

  # Programmatic container packing API: packs an array of preconfigured volumes into a target container.
  def self.pack(
    target : Path | String,
    volumes : Array(Volume),
    append : Bool = true,
  ) : Int64
    writer = Container::Writer.new(target)
    volumes.each { |v| writer.add_volume(v) }
    writer.write(append: append)
  end
end

{% if !flag?(:release) && read_file?("#{__DIR__}/bakelite/docs.cr") %}
  require "./bakelite/docs"
{% end %}
