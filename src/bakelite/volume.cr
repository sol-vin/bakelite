require "file_utils"
require "path"
require "digest/sha256"
require "./types"
require "./item"

module Bakelite
  # Represents an isolated virtual filesystem volume.
  # Volumes manage their own file registry, mount prefix, priority, and default storage policies.
  class Volume
    getter name : String
    getter mount_point : String
    getter mount_prefix_with_slash : String
    property priority : Int32
    property default_chunk_size : UInt32
    property default_compression : CompressionType
    getter items : Hash(String, Item)

    def initialize(
      name : Symbol | String,
      mount_point : String = "",
      @priority : Int32 = 0,
      @default_chunk_size : UInt32 = 65536_u32,
      @default_compression : CompressionType = CompressionType::Deflate,
    )
      @name = name.to_s
      @mount_point = self.class.normalize_path(mount_point)
      @mount_prefix_with_slash = @mount_point.empty? ? "" : "#{@mount_point}/"
      @items = Hash(String, Item).new
    end

    def mount_point=(new_mount : String)
      @mount_point = self.class.normalize_path(new_mount)
      @mount_prefix_with_slash = @mount_point.empty? ? "" : "#{@mount_point}/"
    end

    # Registers an item into this volume.
    def add(item : Item) : Item
      normalized = self.class.normalize_path(item.path)
      @items[normalized] = item
      item
    end

    # Fetches an item by relative path inside this volume. Raises KeyError if missing.
    def get(rel_path : String) : Item
      normalized = self.class.normalize_path(rel_path)
      @items[normalized]? || raise KeyError.new("File '#{rel_path}' not found in volume '#{@name}'")
    end

    # Fetches an item by relative path inside this volume, returning nil if missing.
    def get?(rel_path : String) : Item?
      normalized = self.class.normalize_path(rel_path)
      @items[normalized]?
    end

    # Array access alias for get.
    def [](rel_path : String) : Item
      get(rel_path)
    end

    # Nilable array access alias for get?.
    def []?(rel_path : String) : Item?
      get?(rel_path)
    end

    # Checks if a relative path exists in this volume.
    def has_file?(rel_path : String) : Bool
      normalized = self.class.normalize_path(rel_path)
      @items.has_key?(normalized)
    end

    # Total number of files in this volume.
    def size : Int32
      @items.size
    end

    # Checks if this volume has no files.
    def empty? : Bool
      @items.empty?
    end

    # Returns all relative virtual file paths registered in this volume.
    def files : Array(String)
      @items.keys
    end

    # Iterates over all items in this volume.
    def each_file(&block : Item ->) : Nil
      @items.each_value(&block)
    end

    # Returns a deterministically sorted mapping of normalized relative file paths to SHA-256 hex digests.
    def content_manifest : Hash(String, String)
      manifest = Hash(String, String).new(initial_capacity: @items.size)
      @items.keys.sort.each do |rel_path|
        manifest[rel_path] = @items[rel_path].sha256
      end
      manifest
    end

    # Computes a deterministic SHA-256 manifest digest over all files in this volume.
    # Order-independent: identical files produce an identical 64-character hex digest.
    def manifest_sha256 : String
      hasher = Digest::SHA256.new
      hasher << "bakelite-manifest-v1\n"
      @items.keys.sort.each do |rel_path|
        item = @items[rel_path]
        hasher << rel_path
        hasher << "\0"
        hasher << item.size.to_s
        hasher << "\0"
        hasher << item.crc32_hex
        hasher << "\0"
        hasher << item.sha256
        hasher << "\n"
      end
      hasher.hexfinal
    end

    # Alias for manifest_sha256.
    def sha256 : String
      manifest_sha256
    end

    # Canonical content address URI for this volume's manifest ("sha256:<hex>").
    def content_address : String
      "sha256:#{manifest_sha256}"
    end

    # Finds the first item (in deterministic lexicographical path order) matching a SHA-256 content address.
    def find_by_sha256(digest : String) : Item?
      norm = Item.normalize_sha256(digest)
      @items.keys.sort.each do |rel_path|
        item = @items[rel_path]
        return item if item.sha256 == norm
      end
      nil
    end

    # Alias for find_by_sha256.
    def get_by_sha256?(digest : String) : Item?
      find_by_sha256(digest)
    end

    # Fetches an item by its SHA-256 content address, raising KeyError if not found.
    def get_by_sha256(digest : String) : Item
      find_by_sha256(digest) || raise KeyError.new("Content address '#{digest}' not found in volume '#{@name}'")
    end

    # Finds all items in this volume matching a SHA-256 content address (in deterministic path order).
    def find_all_by_sha256(digest : String) : Array(Item)
      norm = Item.normalize_sha256(digest)
      matched = [] of Item
      @items.keys.sort.each do |rel_path|
        item = @items[rel_path]
        matched << item if item.sha256 == norm
      end
      matched
    end

    # Checks whether an item with the given SHA-256 content address exists in this volume.
    def has_sha256?(digest : String) : Bool
      !find_by_sha256(digest).nil?
    end

    # Returns all relative paths starting with the given prefix.
    def files_with_prefix(prefix : String) : Array(String)
      norm_prefix = self.class.normalize_path(prefix)
      norm_prefix = "#{norm_prefix}/" unless norm_prefix.empty? || norm_prefix.ends_with?('/')
      files.select { |f| f.starts_with?(norm_prefix) }
    end

    # Matches files using glob patterns (e.g. "**/*.png", "textures/*").
    def glob(pattern : String, & : Item ->) : Nil
      norm_pattern = pattern.tr("\\", "/")
      @items.each do |path, item|
        if File.match?(norm_pattern, path)
          yield item
        end
      end
    end

    # Returns an array of items matching the glob pattern.
    def glob(pattern : String) : Array(Item)
      matched = [] of Item
      glob(pattern) { |item| matched << item }
      matched
    end

    # Extracts all files from this volume into destination_dir on disk.
    def extract(destination_dir : Path | String, overwrite : Bool = true) : Int32
      dest_root = Path.new(destination_dir.to_s)
      count = 0
      @items.each do |rel_path, item|
        target_path = dest_root.join(rel_path)
        if item.extract(target_path, overwrite)
          count += 1
        end
      end
      count
    end

    # Extracts a subfolder matching prefix into destination_dir.
    def extract_folder(prefix : String, destination_dir : Path | String, overwrite : Bool = true) : Int32
      dest_root = Path.new(destination_dir.to_s)
      norm_prefix = self.class.normalize_path(prefix)
      norm_prefix = "#{norm_prefix}/" unless norm_prefix.empty? || norm_prefix.ends_with?('/')

      count = 0
      @items.each do |rel_path, item|
        if rel_path.starts_with?(norm_prefix)
          sub_path = rel_path[norm_prefix.size..-1]
          target_path = dest_root.join(sub_path)
          if item.extract(target_path, overwrite)
            count += 1
          end
        end
      end
      count
    end

    # Normalizes directory separators to forward slashes and strips leading/trailing slashes.
    def self.normalize_path(path : String | Path) : String
      path.to_s.tr("\\", "/").strip('/')
    end
  end
end
