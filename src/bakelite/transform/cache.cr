require "digest/sha256"
require "file_utils"
require "path"

module Bakelite
  module Transform
    # Content-addressable cache manager for compile-time asset transformations.
    # Caches the results of expensive external tool executions in `.bakelite/cache/`
    # keyed by SHA256(file_content + command_string), eliminating repeated process invocations.
    class Cache
      getter cache_dir : Path

      def initialize(cache_dir : Path | String = ".bakelite/cache")
        @cache_dir = Path.new(cache_dir.to_s)
      end

      # Computes a deterministic cache key from input bytes and transform command string.
      def compute_key(input_data : Bytes | String, command : String) : String
        hasher = Digest::SHA256.new
        hasher << input_data
        hasher << ":"
        hasher << command
        hasher.hexfinal
      end

      # Checks if a transformed result exists in cache.
      def has_key?(key : String) : Bool
        File.exists?(cache_file_path(key))
      end

      # Retrieves cached output bytes, returning nil on cache miss.
      def get?(key : String) : Bytes?
        target = cache_file_path(key)
        return nil unless File.exists?(target)
        File.read(target).to_slice
      end

      # Stores transformed output bytes into cache.
      def put(key : String, data : Bytes | String) : Nil
        target = cache_file_path(key)
        FileUtils.mkdir_p(target.parent)
        File.write(target, data)
      end

      # Full path to the cache entry file.
      def cache_file_path(key : String) : Path
        @cache_dir.join("#{key}.bin")
      end

      # Clears all entries in the cache directory.
      def clear : Nil
        FileUtils.rm_rf(@cache_dir) if Dir.exists?(@cache_dir)
      end
    end
  end
end
