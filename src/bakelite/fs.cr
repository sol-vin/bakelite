require "file_utils"
require "path"
require "./types"
require "./item"
require "./volume"

module Bakelite
  # Virtual filesystem registry and union-mount router.
  # Can be included in any class/module or used as a standalone filesystem container.
  module FS
    macro included
      include ::Bakelite::DSL

      # Module-level registry instance
      @@fs_instance = ::Bakelite::FS::Registry.new

      def self.fs : ::Bakelite::FS::Registry
        @@fs_instance
      end

      # Direct lookups & routing
      def self.get(path : String) : ::Bakelite::Item
        @@fs_instance.get(path)
      end

      def self.get?(path : String) : ::Bakelite::Item?
        @@fs_instance.get?(path)
      end

      def self.[](path : String) : ::Bakelite::Item
        @@fs_instance.get(path)
      end

      def self.[]?(path : String) : ::Bakelite::Item?
        @@fs_instance.get?(path)
      end

      def self.has_file?(path : String) : Bool
        @@fs_instance.has_file?(path)
      end

      def self.open(path : String) : IO
        @@fs_instance.open(path)
      end

      def self.open(path : String, &block : IO -> T) : T forall T
        @@fs_instance.open(path, &block)
      end

      def self.files : Array(String)
        @@fs_instance.files
      end

      def self.each_file(&block : ::Bakelite::Item ->) : Nil
        @@fs_instance.each_file(&block)
      end

      def self.glob(pattern : String, &block : ::Bakelite::Item ->) : Nil
        @@fs_instance.glob(pattern, &block)
      end

      def self.glob(pattern : String) : Array(::Bakelite::Item)
        @@fs_instance.glob(pattern)
      end

      def self.volume(name : Symbol | String) : ::Bakelite::Volume
        @@fs_instance.volume(name)
      end

      def self.volume(
        name : Symbol | String,
        mount : String = "",
        priority : Int32 = 0,
        &block : ::Bakelite::Volume ->
      ) : ::Bakelite::Volume
        key = name.to_s
        vol = @@fs_instance.volume?(key) || @@fs_instance.mount(::Bakelite::Volume.new(key, mount_point: mount, priority: priority))
        yield vol
        vol
      end

      def self.volume?(name : Symbol | String) : ::Bakelite::Volume?
        @@fs_instance.volume?(name)
      end

      def self.volumes : Array(::Bakelite::Volume)
        @@fs_instance.volumes
      end

      def self.mount(volume : ::Bakelite::Volume) : ::Bakelite::Volume
        @@fs_instance.mount(volume)
      end

      def self.unmount(volume_name : Symbol | String) : Bool
        @@fs_instance.unmount(volume_name)
      end

      def self.mount_file(
        archive_path : String | Path,
        volume_name : Symbol | String | Nil = nil,
        mount : String? = nil,
        priority : Int32 = 0,
      ) : ::Bakelite::Volume?
        @@fs_instance.mount_file(archive_path, volume_name, mount, priority)
      end

      def self.mount_self!(priority : Int32 = 0) : Bool
        @@fs_instance.mount_self!(priority)
      end

      def self.extract_all(destination_dir : Path | String, overwrite : Bool = true) : Int32
        @@fs_instance.extract_all(destination_dir, overwrite)
      end

      def self.extract_folder(prefix : String, destination_dir : Path | String, overwrite : Bool = true) : Int32
        @@fs_instance.extract_folder(prefix, destination_dir, overwrite)
      end
    end

    # Concrete registry implementation managing volumes and union routing
    class Registry
      getter volumes : Array(Volume)
      @volumes_by_name : Hash(String, Volume)
      @root_volume : Volume

      def initialize
        @volumes = [] of Volume
        @volumes_by_name = {} of String => Volume
        @root_volume = Volume.new(:root, mount_point: "", priority: 0)
        mount(@root_volume)
      end

      # Mounts a volume into this registry. Re-sorts volumes by priority descending.
      def mount(volume : Volume) : Volume
        key = volume.name
        if existing = @volumes_by_name[key]?
          @volumes.delete(existing)
        end

        @volumes << volume
        @volumes_by_name[key] = volume
        sort_volumes!
        volume
      end

      # Unmounts a volume by its identifier. Cannot unmount root volume.
      def unmount(volume_name : Symbol | String) : Bool
        key = volume_name.to_s
        return false if key == "root"

        if volume = @volumes_by_name.delete(key)
          @volumes.delete(volume)
          sort_volumes!
          true
        else
          false
        end
      end

      # Retrieves a volume by name. Raises KeyError if missing.
      def volume(name : Symbol | String) : Volume
        key = name.to_s
        @volumes_by_name[key]? || raise KeyError.new("Volume '#{name}' not found in Bakelite registry")
      end

      # Retrieves a volume by name, returning nil if missing.
      def volume?(name : Symbol | String) : Volume?
        @volumes_by_name[name.to_s]?
      end

      # Default root volume for direct bakes without explicit volume declaration.
      def root_volume : Volume
        @root_volume
      end

      # Queries a path across all mounted volumes using union routing.
      # Volumes with higher priority shadow lower-priority volumes.
      def get?(path : String) : Item?
        normalized = Volume.normalize_path(path)

        @volumes.each do |vol|
          prefix = vol.mount_prefix_with_slash

          if prefix.empty?
            # Root mount: direct match in volume
            if item = vol.get?(normalized)
              return item
            end
          else
            # Prefixed mount: check if path begins with mount prefix
            if normalized == vol.mount_point
              if item = vol.get?("")
                return item
              end
            elsif normalized.starts_with?(prefix)
              sub_path = normalized[prefix.size..-1]
              if item = vol.get?(sub_path)
                return item
              end
            end
          end
        end

        nil
      end

      # Queries a path, raising KeyError if not found in any mounted volume.
      def get(path : String) : Item
        get?(path) || raise KeyError.new("Path '#{path}' not found in any mounted Bakelite volume")
      end

      def [](path : String) : Item
        get(path)
      end

      def []?(path : String) : Item?
        get?(path)
      end

      def has_file?(path : String) : Bool
        !get?(path).nil?
      end

      def open(path : String) : IO
        get(path).open
      end

      def open(path : String, &block : IO -> T) : T forall T
        get(path).open(&block)
      end

      # Returns an array of all virtual paths visible through the union router.
      def files : Array(String)
        seen = Set(String).new
        result = [] of String

        @volumes.each do |vol|
          vol.files.each do |rel_file|
            full_path = if vol.mount_point.empty?
                          rel_file
                        else
                          "#{vol.mount_point}/#{rel_file}".strip('/')
                        end
            if seen.add?(full_path)
              result << full_path
            end
          end
        end

        result.sort
      end

      # Iterates over all visible unique items in union priority order.
      def each_file(&block : Item ->) : Nil
        seen = Set(String).new

        @volumes.each do |vol|
          vol.each_file do |item|
            full_path = if vol.mount_point.empty?
                          item.path
                        else
                          "#{vol.mount_point}/#{item.path}".strip('/')
                        end
            if seen.add?(full_path)
              block.call(item)
            end
          end
        end
      end

      # Matches all visible files using glob patterns.
      def glob(pattern : String, &block : Item ->) : Nil
        norm_pattern = pattern.tr("\\", "/")
        seen = Set(String).new

        @volumes.each do |vol|
          vol.each_file do |item|
            full_path = if vol.mount_point.empty?
                          item.path
                        else
                          "#{vol.mount_point}/#{item.path}".strip('/')
                        end
            if File.match?(norm_pattern, full_path) && seen.add?(full_path)
              block.call(item)
            end
          end
        end
      end

      def glob(pattern : String) : Array(Item)
        matched = [] of Item
        glob(pattern) { |item| matched << item }
        matched
      end

      # Mounts an external .bkl archive file or executable overlay
      def mount_file(
        archive_path : String | Path,
        volume_name : Symbol | String | Nil = nil,
        mount : String? = nil,
        priority : Int32 = 0,
      ) : Volume?
        Container::Reader.mount(self, archive_path, volume_name, mount, priority)
      end

      # Automatically inspects Process.executable_path for appended Bakelite volumes
      def mount_self!(priority : Int32 = 0) : Bool
        exe_path = Process.executable_path
        return false unless exe_path && File.exists?(exe_path)

        !mount_file(exe_path, priority: priority).nil?
      end

      # Extracts all visible union files into destination_dir on disk.
      def extract_all(destination_dir : Path | String, overwrite : Bool = true) : Int32
        dest_root = Path.new(destination_dir.to_s)
        count = 0
        seen = Set(String).new

        @volumes.each do |vol|
          vol.each_file do |item|
            full_path = if vol.mount_point.empty?
                          item.path
                        else
                          "#{vol.mount_point}/#{item.path}".strip('/')
                        end
            if seen.add?(full_path)
              target = dest_root.join(full_path)
              if item.extract(target, overwrite)
                count += 1
              end
            end
          end
        end

        count
      end

      # Extracts all visible files matching virtual prefix into destination_dir.
      def extract_folder(prefix : String, destination_dir : Path | String, overwrite : Bool = true) : Int32
        dest_root = Path.new(destination_dir.to_s)
        norm_prefix = Volume.normalize_path(prefix)
        norm_prefix = "#{norm_prefix}/" unless norm_prefix.empty? || norm_prefix.ends_with?('/')

        count = 0
        seen = Set(String).new

        @volumes.each do |vol|
          vol.each_file do |item|
            full_path = if vol.mount_point.empty?
                          item.path
                        else
                          "#{vol.mount_point}/#{item.path}".strip('/')
                        end
            if full_path.starts_with?(norm_prefix) && seen.add?(full_path)
              rel_subpath = full_path[norm_prefix.size..-1]
              target = dest_root.join(rel_subpath)
              if item.extract(target, overwrite)
                count += 1
              end
            end
          end
        end

        count
      end

      private def sort_volumes! : Nil
        # Sort volumes descending by priority (highest priority first)
        @volumes.sort_by! { |v| -v.priority }
      end
    end
  end
end
