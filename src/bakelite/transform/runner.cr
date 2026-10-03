require "file_utils"
require "path"
require "./builtins"
require "./cache"

module Bakelite
  module Transform
    # Executes compile-time or runtime transformations on file data,
    # utilizing built-ins or caching external process results.
    module Runner
      @@cache = Cache.new

      def self.cache : Cache
        @@cache
      end

      # Transforms file content using either a built-in symbol or an external command string.
      def self.run(
        content : String,
        transform : Symbol | String | Nil,
        cache_enabled : Bool = true,
      ) : String
        return content if transform.nil?

        case transform
        when Symbol
          Builtins.apply(transform, content)
        when String
          run_external(content, transform, cache_enabled)
        else
          content
        end
      end

      # Runs an external command with content-addressed caching.
      private def self.run_external(
        content : String,
        command : String,
        cache_enabled : Bool,
      ) : String
        if cache_enabled
          key = @@cache.compute_key(content, command)
          if cached = @@cache.get?(key)
            return String.new(cached)
          end
        end

        # Cache miss: execute command
        output = execute_command(content, command)

        if cache_enabled
          key = @@cache.compute_key(content, command)
          @@cache.put(key, output)
        end

        output
      end

      # Executes the command with %IN% and %OUT% substitution or stdin/stdout piping.
      private def self.execute_command(content : String, command : String) : String
        if command.includes?("%IN%") && command.includes?("%OUT%")
          in_temp = Path.new(Dir.tempdir).join("bakelite_in_#{Time.utc.to_unix_ns}.tmp")
          out_temp = Path.new(Dir.tempdir).join("bakelite_out_#{Time.utc.to_unix_ns}.tmp")

          begin
            File.write(in_temp, content)
            resolved_cmd = command
              .gsub("%IN%", in_temp.to_s.tr("\\", "/"))
              .gsub("%OUT%", out_temp.to_s.tr("\\", "/"))

            status = Process.run(resolved_cmd, shell: true)
            unless status.success?
              raise "Transform command '#{command}' failed with exit code #{status.exit_code}"
            end

            File.exists?(out_temp) ? File.read(out_temp) : ""
          ensure
            File.delete(in_temp) if File.exists?(in_temp)
            File.delete(out_temp) if File.exists?(out_temp)
          end
        else
          # Pipe through stdin and capture stdout
          output_io = IO::Memory.new
          error_io = IO::Memory.new
          input_io = IO::Memory.new(content)

          status = Process.run(command, shell: true, input: input_io, output: output_io, error: error_io)
          unless status.success?
            raise "Transform command '#{command}' failed: #{error_io.to_s}"
          end

          output_io.to_s
        end
      end
    end
  end
end
