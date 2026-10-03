require "base64"
require "./types"
require "./item"
require "./volume"
require "./mime"

module Bakelite
  module DSL
    # Direct compile-time inlined bake of a single file.
    # Inlines static bytes into the binary for zero-copy, instantaneous string reads.
    macro bake(path, as_path = nil, volume = :root, transform = nil)
      {% if as_path %}
        {% v_path = as_path %}
      {% else %}
        {% v_path = path %}
      {% end %}

      {% if transform %}
        {% tr_arg = transform.to_s %}
      {% else %}
        {% tr_arg = "none" %}
      {% end %}

      {%
        raw_data = run("./compile_helper.cr", "process_file", path, "bake", "65536", "none", tr_arg)
        lines = raw_data.strip.split("\n")
        b64 = ""
        crc = 0_u32
        size = 0_i64
      %}
      {% for line in lines %}
        {%
          parts = line.split("|")
          if parts[0] == "META"
            size = parts[2].to_i
            crc = parts[4].to_i
          elsif parts[0] == "DATA"
            b64 = parts[1]
          end
        %}
      {% end %}
      %vol = fs.volume?({{ volume }}) || fs.mount(::Bakelite::Volume.new({{ volume }}))
      %data = ::Base64.decode({{ b64 }})
      %item = ::Bakelite::BakedItem.new(
        path: {{ v_path }},
        volume_name: {{ volume }},
        data: %data,
        mime_type: ::Bakelite::MIME.from_path({{ v_path }}),
        crc32: {{ crc }}.to_u32
      )
      %vol.add(%item)
    end

    # Chunked, compressed, and stream-backed store of a file.
    # Reads through Bakelite::FileIO in O(chunk_size) RAM.
    macro store(path, as_path = nil, volume = :root, chunk_size = 65536, compress = :deflate, transform = nil)
      {% if as_path %}
        {% v_path = as_path %}
      {% else %}
        {% v_path = path %}
      {% end %}

      {% if transform %}
        {% tr_arg = transform.to_s %}
      {% else %}
        {% tr_arg = "none" %}
      {% end %}

      {%
        raw_data = run("./compile_helper.cr", "process_file", path, "store", "#{chunk_size.id}", "#{compress.id}", tr_arg)
        lines = raw_data.strip.split("\n")
        total_size = 0
        total_compressed = 0
        crc = 0
        comp_sym = "#{compress.id}"
        chunks_meta = [] of Hash(String, String)
      %}
      {% for line in lines %}
        {%
          parts = line.split("|")
          if parts[0] == "META"
            total_size = parts[2].to_i
            total_compressed = parts[3].to_i
            crc = parts[4].to_i
            comp_sym = parts[5]
          elsif parts[0] == "CHUNK"
            chunks_meta << {
              "offset"      => parts[1],
              "comp_size"   => parts[2],
              "uncomp_size" => parts[3],
              "crc"         => parts[4],
              "b64"         => parts[5],
            }
          end
        %}
      {% end %}
      %chunks = [] of ::Bakelite::Chunk
      {% for c in chunks_meta %}
        %chunks << ::Bakelite::Chunk.new(
          offset: {{ c["offset"].id }}_i64,
          compressed_size: {{ c["comp_size"].id }}_u32,
          uncompressed_size: {{ c["uncomp_size"].id }}_u32,
          crc32: {{ c["crc"].id }}_u32,
          data: ::Base64.decode({{ c["b64"] }})
        )
      {% end %}
      %item = ::Bakelite::StoredItem.new(
        path: {{ v_path }},
        volume_name: {{ volume }},
        size: {{ total_size }}.to_i64,
        compressed_size: {{ total_compressed }}.to_i64,
        chunks: %chunks,
        compression: ::Bakelite::CompressionType.from_symbol({{ comp_sym }}),
        mime_type: ::Bakelite::MIME.from_path({{ v_path }}),
        crc32: {{ crc }}.to_u32
      )
      %vol = fs.volume?({{ volume }}) || fs.mount(::Bakelite::Volume.new({{ volume }}))
      %vol.add(%item)
    end

    # Embeds all files in a folder directly as inlined bakes using single-pass batch processing.
    macro bake_folder(dir, prefix = "", volume = :root, transform = nil, exclude = [] of String)
      {{ run("./compile_helper.cr", "batch_process", "folder", "bake", dir, prefix, "#{volume.id}", "65536", "none", (transform ? transform.to_s : "none"), exclude.join(",")) }}
    end

    # Stores all files in a folder as chunked, compressed streaming assets using single-pass batch processing.
    macro store_folder(dir, prefix = "", volume = :root, chunk_size = 65536, compress = :deflate, transform = nil, exclude = [] of String)
      {{ run("./compile_helper.cr", "batch_process", "folder", "store", dir, prefix, "#{volume.id}", "#{chunk_size.id}", "#{compress.id}", (transform ? transform.to_s : "none"), exclude.join(",")) }}
    end

    # Smart auto-embedding using single-pass batch processing: inlines small text files, chunks large files.
    macro embed_folder(dir, prefix = "", volume = :root, auto = true, threshold = 16384, chunk_size = 65536, compress = :deflate, exclude = [] of String)
      {{ run("./compile_helper.cr", "batch_process", "folder", "auto", dir, prefix, "#{volume.id}", "#{chunk_size.id}", "#{compress.id}", "none", exclude.join(","), "#{threshold.id}") }}
    end

    # Declarative multi-volume manifest baking.
    # Reads a YAML manifest defining volumes, mount points, chunk sizes, compression,
    # auto thresholds, file inclusion globs, and negative/exclusion patterns.
    # Processes all volumes and assets in a single ultra-fast pass (<200ms).
    macro bake_manifest(manifest_path, base_dir = ".")
      {{ run("./compile_helper.cr", "batch_process", "manifest", manifest_path, base_dir) }}
    end

    # Creates and mounts a custom volume with specific mount point, chunk size, and priority.
    macro volume(name, mount = "", priority = 0, chunk_size = 65536, compress = :deflate, &block)
      %vol = fs.volume?({{ name }}) || fs.mount(::Bakelite::Volume.new(
        name: {{ name }},
        mount_point: {{ mount }},
        priority: {{ priority }},
        default_chunk_size: {{ chunk_size }}.to_u32,
        default_compression: ::Bakelite::CompressionType.from_symbol({{ compress }})
      ))
      {{ block.body }}
    end

    # Macro alias for volume definition
    macro define_volume(name, mount = "", priority = 0, chunk_size = 65536, compress = :deflate, &block)
      volume({{ name }}, mount: {{ mount }}, priority: {{ priority }}, chunk_size: {{ chunk_size }}, compress: {{ compress }}) do
        {{ block.body }}
      end
    end
  end
end
