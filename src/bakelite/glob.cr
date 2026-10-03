module Bakelite
  # Advanced pattern matching and globbing utilities supporting recursive wildcards,
  # extensions, directory boundaries, and negative pattern exclusions (!pattern).
  module Glob
    # Evaluates if a relative file path matches the given include and exclude rules,
    # including negative patterns (e.g. "!src/main.cr").
    def self.match?(
      path : String,
      patterns : Array(String) = ["**/*"],
      excludes : Array(String) = [] of String,
    ) : Bool
      norm_path = path.tr("\\", "/").strip('/')

      # 1. Separate negative patterns from include patterns
      pos_patterns = [] of String
      neg_patterns = [] of String

      excludes.each do |e|
        cleaned = e.tr("\\", "/").strip('/')
        next if cleaned.empty?
        cleaned = cleaned[1..-1] if cleaned.starts_with?('!')
        neg_patterns << cleaned
      end

      patterns.each do |p|
        cleaned = p.tr("\\", "/").strip('/')
        next if cleaned.empty?
        if cleaned.starts_with?('!')
          neg_patterns << cleaned[1..-1]
        else
          pos_patterns << cleaned
        end
      end

      pos_patterns << "**/*" if pos_patterns.empty?

      # 2. Check if matched by negative pattern
      if neg_patterns.any? { |np| matches_pattern?(norm_path, np) }
        return false
      end

      # 3. Check if matched by positive pattern
      pos_patterns.any? { |pp| matches_pattern?(norm_path, pp) }
    end

    # Tests a single path against a single glob pattern
    def self.matches_pattern?(path : String, pattern : String) : Bool
      norm_pattern = pattern.tr("\\", "/").strip('/')
      return true if norm_pattern == "**" || norm_pattern == "**/*"
      return true if path == norm_pattern

      # If pattern doesn't contain a slash and contains wildcards, match against basename as well (e.g. "*.uid" matches "a/b/c.uid")
      if !norm_pattern.includes?('/') && (norm_pattern.includes?('*') || norm_pattern.includes?('?')) && File.match?(norm_pattern, File.basename(path))
        return true
      end

      # Standard File.match?
      return true if File.match?(norm_pattern, path)

      # Recursive wildcard matching (e.g. "dir/**" or "dir/**/*")
      if norm_pattern.ends_with?("/**") || norm_pattern.ends_with?("/**/*")
        prefix = norm_pattern.ends_with?("/**/*") ? norm_pattern.rchop("/**/*") : norm_pattern.rchop("/**")
        if prefix.starts_with?("**/")
          inner_prefix = prefix.lchop("**/")
          return true if path == inner_prefix || path.starts_with?("#{inner_prefix}/") || path.includes?("/#{inner_prefix}/") || path.ends_with?("/#{inner_prefix}")
        else
          return true if path == prefix || path.starts_with?("#{prefix}/")
        end
      elsif norm_pattern.ends_with?("/*")
        prefix = norm_pattern.rchop("/*")
        if prefix.starts_with?("**/")
          inner_prefix = prefix.lchop("**/")
          if path.starts_with?("#{inner_prefix}/")
            sub = path[(inner_prefix.size + 1)..-1]
            return !sub.includes?('/')
          elsif path.includes?("/#{inner_prefix}/")
            sub = path.split("/#{inner_prefix}/", 2)[1]
            return !sub.includes?('/')
          end
        else
          if path.starts_with?("#{prefix}/")
            sub = path[(prefix.size + 1)..-1]
            return !sub.includes?('/')
          end
        end
      end

      # Extension wildcard anywhere in path (e.g. "**/*.uid" or "*.uid")
      if norm_pattern.starts_with?("**/*.")
        ext = norm_pattern.lchop("**/*.")
        return true if path.ends_with?(".#{ext}")
      elsif norm_pattern.starts_with?("*.")
        ext = norm_pattern.lchop("*.")
        return true if path.ends_with?(".#{ext}")
      end

      false
    end
  end
end
