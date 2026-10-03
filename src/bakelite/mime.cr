require "path"

module Bakelite
  module MIME
    MIME_TYPES = {
      # Text & Documents
      "txt"  => "text/plain; charset=utf-8",
      "html" => "text/html; charset=utf-8",
      "htm"  => "text/html; charset=utf-8",
      "css"  => "text/css; charset=utf-8",
      "js"   => "application/javascript; charset=utf-8",
      "mjs"  => "application/javascript; charset=utf-8",
      "json" => "application/json",
      "yml"  => "application/yaml",
      "yaml" => "application/yaml",
      "xml"  => "application/xml",
      "md"   => "text/markdown; charset=utf-8",
      "csv"  => "text/csv; charset=utf-8",
      "cr"   => "text/x-crystal; charset=utf-8",
      "cpp"  => "text/x-c++src; charset=utf-8",
      "hpp"  => "text/x-c++hdr; charset=utf-8",
      "h"    => "text/x-chdr; charset=utf-8",

      # Images & Vectors
      "png"  => "image/png",
      "jpg"  => "image/jpeg",
      "jpeg" => "image/jpeg",
      "gif"  => "image/gif",
      "webp" => "image/webp",
      "svg"  => "image/svg+xml",
      "ico"  => "image/x-icon",
      "bmp"  => "image/bmp",
      "tiff" => "image/tiff",
      "tif"  => "image/tiff",

      # Audio
      "ogg"  => "audio/ogg",
      "oga"  => "audio/ogg",
      "mp3"  => "audio/mpeg",
      "wav"  => "audio/wav",
      "flac" => "audio/flac",
      "aac"  => "audio/aac",
      "m4a"  => "audio/mp4",
      "opus" => "audio/opus",

      # Video
      "mp4"  => "video/mp4",
      "webm" => "video/webm",
      "ogv"  => "video/ogg",
      "mkv"  => "video/x-matroska",
      "avi"  => "video/x-msvideo",

      # Fonts
      "woff"  => "font/woff",
      "woff2" => "font/woff2",
      "ttf"   => "font/ttf",
      "otf"   => "font/otf",

      # 3D, Shaders & Game Assets
      "gltf" => "model/gltf+json",
      "glb"  => "model/gltf-binary",
      "obj"  => "model/obj",
      "spv"  => "application/x-spirv",
      "glsl" => "text/x-glsl",
      "vert" => "text/x-glsl",
      "frag" => "text/x-glsl",
      "comp" => "text/x-glsl",
      "pck"  => "application/x-godot-pack",
      "tscn" => "text/x-godot-scene",
      "tres" => "text/x-godot-resource",
      "gd"   => "text/x-gdscript",

      # Archives & Binaries
      "bkl"  => "application/x-bakelite-archive",
      "zip"  => "application/zip",
      "tar"  => "application/x-tar",
      "gz"   => "application/gzip",
      "wasm" => "application/wasm",
      "bin"  => "application/octet-stream",
    }

    # Resolves the MIME type for a given filename or virtual path.
    # Defaults to "application/octet-stream" if extension is unknown.
    def self.from_path(path : String | Path) : String
      ext = Path.new(path.to_s).extension.downcase.lchop('.')
      MIME_TYPES[ext]? || "application/octet-stream"
    end
  end
end
