# Bakelite

**Next-generation BakedFS, virtual filesystem, and binary container engine for Crystal.**

Bakelite provides zero-copy compile-time asset embedding alongside streaming-capable, chunked-compressed storage and post-compilation binary overlay containers.

[![CI](https://github.com/sol-vin/bakelite/actions/workflows/ci.yml/badge.svg)](https://github.com/sol-vin/bakelite/actions/workflows/ci.yml)
[![Pages](https://github.com/sol-vin/bakelite/actions/workflows/pages.yml/badge.svg)](https://sol-vin.github.io/bakelite/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Features

- **Dual Storage Paradigm**:
  - `bake`: Inlines raw static bytes directly into the Crystal binary for zero-copy, instantaneous string reads. Ideal for shaders, configs, templates, and crucial YAML/JSON definitions.
  - `store`: Slices assets into compressed chunks (Deflate, Gzip, Zlib) streamed on demand.
- **Constant Memory Streaming (`Bakelite::FileIO`)**:
  - Transparent `IO` implementation guaranteeing bounded memory usage ($O(\text{chunk\_size})$) regardless of whether the file is 1MB or 2GB.
  - Supports random seeking (`Seek::Set`, `Seek::Current`, `Seek::End`) across chunk boundaries with active chunk decompression caching.
- **Custom Volumes & Union Routing**:
  - Isolate subsystems into named volumes (`Volume`) with custom mount points, priority shadowing, and unmounting.
  - Perfect for mod systems, DLC layering, and multi-tenant asset management.
- **Compile-Time Content-Addressed Transforms**:
  - Run built-in transformations (`:crlf_to_lf`, `:minify_json`, `:strip_comments`, `:trim`) or external CLI pipelines at compile time.
  - Results are cached by SHA-256 hash in `.bakelite/cache` to prevent redundant rebuild overhead.
- **Post-Compile Executable Overlay Container**:
  - Pack assets into `.bkl` standalone archives or append them directly onto compiled executables (PE, ELF, Mach-O).
  - 32-byte fixed EOF trailer allows executables to inspect and mount their own embedded payload at runtime via `mount_self!`.
- **Ecosystem Integration**:
  - Versioning powered by `sol-vin/carbon`.
  - ANSI TUI tables and CLI styling powered by `sol-vin/opal`.
  - Structured multi-track guide compiler powered by `sol-vin/jasper`.

---

## Installation

Add `bakelite` to your `shard.yml`:

```yaml
dependencies:
  bakelite:
    github: sol-vin/bakelite
    version: ~> 0.1.0
```

Run `shards install`.

---

## Quick Start

### 1. Macro DSL Embedding

```crystal
require "bakelite"

module Assets
  include Bakelite::FS

  # Direct inlined bake (zero-copy string/bytes)
  bake "config/app.yml", as_path: "app.yml"

  # Streamed chunked store (64KB chunks, Deflate compressed)
  store "media/soundtrack.ogg", chunk_size: 65536, compress: :deflate

  # Embed entire directories
  bake_folder "public/icons", prefix: "icons"
  store_folder "assets/models", prefix: "models"
end

# Read baked content directly
puts Assets["app.yml"].content

# Stream large files through standard Crystal IO
Assets.open("media/soundtrack.ogg") do |io|
  io.seek(1024)
  buffer = Bytes.new(512)
  io.read_fully(buffer)
end
```

### 2. Custom Volumes & Union Mounts

```crystal
module Game
  include Bakelite::FS

  # Define a dedicated volume mounted at /mods with high priority
  volume :mods, mount: "mods", priority: 100 do
    bake "mods/pack1/rules.json", as_path: "rules.json"
  end
end

# Access files via mount prefix or direct volume reference
item = Game["mods/rules.json"]
mod_item = Game.volume(:mods)["rules.json"]
```

### 3. Appending Containers Post-Compilation

Compile your application normally:

```bash
crystal build src/main.cr -o bin/game.exe
```

Append assets into the binary using the `bakelite` CLI:

```bash
bakelite pack bin/game.exe assets/ --mount assets --append
```

Inside `src/main.cr`, mount the appended container on startup:

```crystal
require "bakelite"

Bakelite.mount_self!

# All assets are now available transparently!
if item = Bakelite.get?("assets/textures/player.png")
  puts "Found asset: #{item.size} bytes"
end
```

---

## CLI Reference

Bakelite ships with a complete CLI tool for managing containers and documentation:

```bash
# Pack a directory into a .bkl archive or append to an executable
bakelite pack <target> <dir> [--mount PATH] [--append] [--chunk-size 64KB] [--compress deflate]

# List files and volumes in a container with rich Opal tables
bakelite list <target>

# Inspect container trailer, start offset, index metadata, and mounted volumes
bakelite inspect <target>

# Verify CRC32 checksums for every chunk in a container
bakelite verify <target>

# Extract all files or a specific volume to disk
bakelite extract <target> <destination> [--volume NAME]

# Compile structured guide documentation with Jasper
bakelite docs [--src docs_src] [--out src/bakelite/docs]

# Display version information
bakelite version
```

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────┐
│                       Bakelite::FS                          │
│                      (Union Router)                         │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
       Priority 100                    Priority 0
┌──────────────▼──────────────┐ ┌──────────────▼──────────────┐
│       Volume (:dlc)         │ │       Volume (:root)        │
│   Mount: "content/dlc"      │ │       Mount: ""             │
└──────────────┬──────────────┘ └──────────────┬──────────────┘
               │                               │
       ┌───────┴───────┐               ┌───────┴───────┐
       │               │               │               │
┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
│  BakedItem  │ │ StoredItem  │ │  BakedItem  │ │ StoredItem  │
│ (Inlined)   │ │  (Chunked)  │ │ (Inlined)   │ │  (Chunked)  │
└─────────────┘ └──────┬──────┘ └─────────────┘ └──────┬──────┘
                       │                               │
              ┌────────▼────────┐             ┌────────▼────────┐
              │ Bakelite::FileIO│             │ Bakelite::FileIO│
              │ O(chunk) Memory │             │ O(chunk) Memory │
              └─────────────────┘             └─────────────────┘
```

---

## Running Specs

```bash
# Run full test suite
crystal spec

# Or compile and run dedicated runner
crystal build spec/all_specs.cr -o bin/all_specs.exe
./bin/all_specs.exe
```

---

## License

MIT License. Copyright (c) 2026 sol-vin.
