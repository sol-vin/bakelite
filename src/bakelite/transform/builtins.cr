require "json"

module Bakelite
  module Transform
    # Built-in pure Crystal compile-time transforms that execute with zero subprocess overhead.
    module Builtins
      # Normalizes Windows CRLF line endings to UNIX LF.
      def self.crlf_to_lf(content : String) : String
        content.gsub("\r\n", "\n")
      end

      # Trims leading and trailing whitespace.
      def self.trim(content : String) : String
        content.strip
      end

      # Strips hash-style (# ...) and double-slash (// ...) single-line comments.
      def self.strip_comments(content : String) : String
        lines = [] of String
        content.each_line do |line|
          stripped = line.strip
          next if stripped.starts_with?('#') || stripped.starts_with?("//")
          lines << line
        end
        lines.join("\n")
      end

      # Minifies JSON by stripping extraneous whitespace and formatting.
      def self.minify_json(content : String) : String
        parsed = JSON.parse(content)
        parsed.to_json
      rescue
        content
      end

      # Applies a built-in transform by name (:crlf_to_lf, :trim, :strip_comments, :minify_json)
      def self.apply(name : Symbol | String, content : String) : String
        case name.to_s.lchop(':')
        when "crlf_to_lf"
          crlf_to_lf(content)
        when "trim"
          trim(content)
        when "strip_comments"
          strip_comments(content)
        when "minify_json"
          minify_json(content)
        else
          content
        end
      end
    end
  end
end
