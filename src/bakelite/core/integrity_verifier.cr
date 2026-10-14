require "json"
require "yaml"
require "digest/crc32"
require "digest/sha256"
require "compress/deflate"
require "compress/gzip"
require "compress/zlib"
require "../types"
require "../item"
require "../volume"
require "../fs"
require "../container/format"
require "../container/reader"

module Bakelite
  module Core
    # Default maximum decompressed bytes per file during verification (1 GB)
    DEFAULT_MAX_DECOMPRESSED_BYTES = 1_073_741_824_i64

    # Classification of archive or virtual filesystem integrity violations.
    enum ViolationKind
      CorruptContainer
      MissingFile
      UnexpectedFile
      SizeMismatch
      ChunkCrc32Mismatch
      FileCrc32Mismatch
      Sha256Mismatch
      ManifestDigestMismatch
      InvariantFailure
    end

    # Structured record describing a single integrity violation detected during verification.
    struct IntegrityViolation
      include JSON::Serializable
      include YAML::Serializable

      getter kind : ViolationKind
      getter path : String?
      getter volume_name : String?
      getter expected : String?
      getter actual : String?
      getter message : String
      getter chunk_index : Int32?

      def initialize(
        @kind : ViolationKind,
        @message : String,
        @path : String? = nil,
        @volume_name : String? = nil,
        @expected : String? = nil,
        @actual : String? = nil,
        @chunk_index : Int32? = nil,
      )
      end
    end

    # Per-file verification telemetry and computed content digests.
    struct FileVerificationEntry
      include JSON::Serializable
      include YAML::Serializable

      getter path : String
      getter volume_name : String
      getter size : Int64
      getter actual_size : Int64
      getter compressed_size : Int64
      getter crc32 : UInt32
      getter actual_crc32 : UInt32
      getter sha256 : String
      getter expected_sha256 : String?
      getter chunks_verified : Int32
      getter valid : Bool
      getter error_message : String?

      def initialize(
        @path : String,
        @volume_name : String,
        @size : Int64,
        @actual_size : Int64,
        @compressed_size : Int64,
        @crc32 : UInt32,
        @actual_crc32 : UInt32,
        @sha256 : String,
        @chunks_verified : Int32 = 0,
        @valid : Bool = true,
        @expected_sha256 : String? = nil,
        @error_message : String? = nil,
      )
      end

      def valid? : Bool
        @valid
      end

      def crc32_hex : String
        sprintf("%08x", @crc32)
      end

      def actual_crc32_hex : String
        sprintf("%08x", @actual_crc32)
      end

      def content_address : String
        "sha256:#{@sha256}"
      end
    end

    # Deterministic, serializable SHA-256 content-addressed manifest of an archive or volume.
    class ArchiveManifest
      include JSON::Serializable
      include YAML::Serializable

      getter version : Int32
      getter algorithm : String
      getter manifest_sha256 : String
      getter total_files : Int32
      getter total_bytes : Int64
      getter files : Hash(String, String)
      getter entries : Array(FileVerificationEntry)

      def initialize(
        @manifest_sha256 : String,
        @total_files : Int32,
        @total_bytes : Int64,
        @files : Hash(String, String),
        @entries : Array(FileVerificationEntry) = [] of FileVerificationEntry,
        @version : Int32 = 1,
        @algorithm : String = "sha256",
      )
      end

      def [](path : String) : String
        norm = Volume.normalize_path(path)
        @files[norm]
      end

      def []?(path : String) : String?
        norm = Volume.normalize_path(path)
        @files[norm]?
      end

      def content_address : String
        "sha256:#{@manifest_sha256}"
      end
    end

    # Comprehensive verification report returned by Bakelite::Core::IntegrityVerifier and Bakelite.verify_archive.
    class VerificationReport
      include JSON::Serializable
      include YAML::Serializable

      getter target_name : String
      getter valid : Bool
      getter total_volumes : Int32
      getter total_files : Int32
      getter verified_files : Int32
      getter total_chunks : Int32
      getter verified_chunks : Int32
      getter total_bytes : Int64
      getter manifest_sha256 : String
      getter container_sha256 : String?
      getter duration_seconds : Float64
      getter entries : Array(FileVerificationEntry)
      getter violations : Array(IntegrityViolation)
      getter content_manifest : Hash(String, String)

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      property root_exception : Exception?

      def initialize(
        @target_name : String,
        @valid : Bool,
        @total_volumes : Int32,
        @total_files : Int32,
        @verified_files : Int32,
        @total_chunks : Int32,
        @verified_chunks : Int32,
        @total_bytes : Int64,
        @manifest_sha256 : String,
        @duration_seconds : Float64,
        @entries : Array(FileVerificationEntry) = [] of FileVerificationEntry,
        @violations : Array(IntegrityViolation) = [] of IntegrityViolation,
        @content_manifest : Hash(String, String) = {} of String => String,
        @container_sha256 : String? = nil,
        @root_exception : Exception? = nil,
      )
      end

      def valid? : Bool
        @valid && @violations.empty?
      end

      def clean? : Bool
        valid?
      end

      def passed? : Bool
        valid?
      end

      def failed? : Bool
        !valid?
      end

      def errors_count : Int32
        @violations.size
      end

      def content_address : String
        "sha256:#{@manifest_sha256}"
      end

      # Looks up the computed SHA-256 hex digest for a virtual file path.
      def sha256_for(path : String) : String?
        norm = Volume.normalize_path(path)
        @content_manifest[norm]? || @entries.find { |e| e.path == norm }.try(&.sha256)
      end

      # Looks up the FileVerificationEntry for a virtual file path.
      def entry_for(path : String) : FileVerificationEntry?
        norm = Volume.normalize_path(path)
        @entries.find { |e| e.path == norm }
      end

      # Exports the verified entries as a deterministic ArchiveManifest.
      def to_manifest : ArchiveManifest
        ArchiveManifest.new(
          manifest_sha256: @manifest_sha256,
          total_files: @total_files,
          total_bytes: @total_bytes,
          files: @content_manifest.dup,
          entries: @entries.dup
        )
      end

      # Raises IntegrityError (or the underlying container error) if verification failed.
      def assert_valid! : self
        return self if valid?

        if ex = @root_exception
          raise ex if ex.is_a?(InvalidTrailerError) || ex.is_a?(CorruptContainerError)
        end

        msg = String.build do |io|
          io << "Bakelite archive verification failed for '" << @target_name << "' with " << @violations.size << " violation(s):\n"
          @violations.first(10).each_with_index do |v, idx|
            io << "  [" << (idx + 1) << "] " << v.kind << ": " << v.message
            if p = v.path
              io << " (path: " << p << ")"
            end
            if exp = v.expected
              io << " [expected: " << exp << ", actual: " << (v.actual || "none") << "]"
            end
            io << "\n"
          end
        end

        raise IntegrityError.new(msg)
      end

      def verify! : self
        assert_valid!
      end

      def assert_clean! : self
        assert_valid!
      end

      # Renders a Markdown summary report of the integrity verification run.
      def to_markdown : String
        String.build do |io|
          badge = valid? ? "PASS" : "FAIL"
          io << "# [Bakelite Archive Integrity: " << badge << "] " << @target_name << "\n\n"
          io << "- **Manifest SHA-256**: `" << @manifest_sha256 << "`\n"
          if c_sha = @container_sha256
            io << "- **Container SHA-256**: `" << c_sha << "`\n"
          end
          io << "- **Volumes**: `" << @total_volumes << "` | **Files**: `" << @verified_files << "/" << @total_files << "`\n"
          io << "- **Chunks Verified**: `" << @verified_chunks << "/" << @total_chunks << "` | **Total Bytes**: `" << @total_bytes << "`\n"
          io << "- **Violations**: `" << @violations.size << "` | **Duration**: `" << @duration_seconds << "s`\n"

          unless @entries.empty?
            io << "\n## Content-Addressed Manifest Entries\n\n"
            io << "| Path | Volume | Size (B) | CRC32 | SHA-256 | Status |\n"
            io << "| :--- | :--- | :--- | :--- | :--- | :--- |\n"
            @entries.each do |e|
              st = e.valid? ? "OK" : "FAIL"
              io << "| `" << e.path << "` | `:" << e.volume_name << "` | `" << e.size << "` | `" << e.crc32_hex << "` | `" << e.sha256 << "` | " << st << " |\n"
            end
          end

          unless @violations.empty?
            io << "\n## Integrity Violations\n\n"
            @violations.each do |v|
              io << "- **[" << v.kind << "]** " << v.message << "\n"
            end
          end
        end
      end
    end

    # Tier 1 Core Engine: Streaming SHA-256 content-addressing & CRC32 chunk integrity verifier
    # for Bakelite binary containers (.bkl), appended executables, volumes, and virtual filesystems.
    class IntegrityVerifier
      property verify_crc32 : Bool
      property verify_chunks : Bool
      property verify_sha256 : Bool
      property strict_manifest : Bool
      property fail_fast : Bool
      property volume_filter : String?
      property expected_digests : Hash(String, String)
      property expected_crc32s : Hash(String, UInt32)
      property required_files : Set(String)
      property expected_manifest_sha256 : String?
      property max_decompressed_bytes : Int64
      property invariants : Array(Tuple(String, Proc(VerificationReport, Bool)))

      def initialize(
        @verify_crc32 : Bool = true,
        @verify_chunks : Bool = true,
        @verify_sha256 : Bool = true,
        @strict_manifest : Bool = false,
        @fail_fast : Bool = false,
        @volume_filter : String? = nil,
        expected_digests : Hash(String, String) = {} of String => String,
        expected_crc32s : Hash(String, UInt32) = {} of String => UInt32,
        required_files : Enumerable(String) = [] of String,
        expected_manifest_sha256 : String? = nil,
        @max_decompressed_bytes : Int64 = DEFAULT_MAX_DECOMPRESSED_BYTES,
      )
        @expected_digests = Hash(String, String).new
        expected_digests.each { |k, v| expect_digest(k, v) }

        @expected_crc32s = Hash(String, UInt32).new
        expected_crc32s.each { |k, v| expect_crc32(k, v) }

        @required_files = Set(String).new
        required_files.each { |f| require_file(f) }

        @expected_manifest_sha256 = expected_manifest_sha256 ? self.class.normalize_sha256(expected_manifest_sha256) : nil
        @invariants = [] of Tuple(String, Proc(VerificationReport, Bool))
      end

      # Normalizes a SHA-256 hex digest string (strips optional "sha256:" prefix and downcases).
      def self.normalize_sha256(digest : String) : String
        Item.normalize_sha256(digest)
      end

      # Computes the canonical deterministic SHA-256 manifest digest across a list of FileVerificationEntry items.
      def self.compute_manifest_sha256(entries : Array(FileVerificationEntry)) : String
        sorted = entries.sort_by(&.path)
        hasher = Digest::SHA256.new
        hasher << "bakelite-manifest-v1\n"
        sorted.each do |entry|
          hasher << entry.path
          hasher << "\0"
          hasher << entry.size.to_s
          hasher << "\0"
          hasher << entry.crc32_hex
          hasher << "\0"
          hasher << entry.sha256
          hasher << "\n"
        end
        hasher.hexfinal
      end

      # Registers an expected SHA-256 hex digest for a virtual file path.
      def expect_digest(path : String, sha256 : String) : self
        norm_path = Volume.normalize_path(path)
        @expected_digests[norm_path] = self.class.normalize_sha256(sha256)
        @required_files << norm_path
        self
      end

      # Alias for expect_digest.
      def expect_sha256(path : String, sha256 : String) : self
        expect_digest(path, sha256)
      end

      # Registers a full map of expected file SHA-256 digests.
      def expect_manifest(digests : Hash(String, String), strict : Bool = false) : self
        digests.each { |path, sha| expect_digest(path, sha) }
        @strict_manifest = true if strict
        self
      end

      # Registers an expected ArchiveManifest instance.
      def expect_manifest(manifest : ArchiveManifest, strict : Bool = true) : self
        expect_manifest(manifest.files, strict: strict)
        expect_manifest_sha256(manifest.manifest_sha256)
        self
      end

      # Registers the expected overall deterministic manifest SHA-256 digest.
      def expect_manifest_sha256(digest : String) : self
        @expected_manifest_sha256 = self.class.normalize_sha256(digest)
        self
      end

      # Registers an expected CRC32 checksum for a virtual file path.
      def expect_crc32(path : String, crc32 : UInt32) : self
        norm_path = Volume.normalize_path(path)
        @expected_crc32s[norm_path] = crc32
        @required_files << norm_path
        self
      end

      # Declares that a virtual file path must exist in the verified archive.
      def require_file(path : String) : self
        @required_files << Volume.normalize_path(path)
        self
      end

      # Declares multiple required virtual file paths.
      def require_files(paths : Enumerable(String)) : self
        paths.each { |p| require_file(p) }
        self
      end

      # Registers a custom verification invariant predicate.
      def add_invariant(name : String = "invariant_#{@invariants.size + 1}", &block : VerificationReport -> Bool) : self
        @invariants << {name, block}
        self
      end

      # Polymorphic verification dispatch for paths, byte buffers, streams, volumes, or registries.
      def verify(
        target : Path | String | Bytes | IO | Volume | FS::Registry | Array(Volume),
      ) : VerificationReport
        case target
        when Path, String
          verify_file(target)
        when Bytes
          verify_bytes(target)
        when IO
          verify_io(target)
        when Volume
          verify_volume(target)
        when Array(Volume)
          verify_volumes(target)
        when FS::Registry
          verify_registry(target)
        else
          raise ArgumentError.new("Unsupported verification target: #{target.class}")
        end
      end

      # Executes verification and raises IntegrityError / CorruptContainerError / InvalidTrailerError on failure.
      def verify!(
        target : Path | String | Bytes | IO | Volume | FS::Registry | Array(Volume),
      ) : VerificationReport
        verify(target).assert_valid!
      end

      # Verifies a standalone .bkl archive or executable overlay on disk.
      def verify_file(archive_path : Path | String) : VerificationReport
        started = Time.instant
        path = Path.new(archive_path.to_s)
        target_label = path.to_s

        unless File.exists?(path)
          err = File::NotFoundError.new("Archive file not found", file: path)
          return build_container_error_report(target_label, started, "Archive file not found: #{path}", err)
        end

        container_sha = compute_file_sha256(path)
        reader = Container::Reader.new(path)
        begin
          volumes = reader.read
          verify_volumes_internal(
            volumes: volumes,
            target_name: target_label,
            started_instant: started,
            container_sha256: container_sha
          )
        rescue ex : Error
          build_container_error_report(target_label, started, ex.message || ex.class.name, ex, container_sha)
        rescue ex : Exception
          wrapped = CorruptContainerError.new("Unhandled container error in #{target_label}: #{ex.message}")
          build_container_error_report(target_label, started, wrapped.message || "Corrupt container", wrapped, container_sha)
        ensure
          reader.close
        end
      end

      # Verifies an in-memory .bkl container byte slice.
      def verify_bytes(bytes : Bytes, source_name : String = "<memory>") : VerificationReport
        started = Time.instant
        container_sha = Digest::SHA256.hexdigest(bytes)
        reader = Container::Reader.new(bytes, source_name)
        begin
          volumes = reader.read
          verify_volumes_internal(
            volumes: volumes,
            target_name: source_name,
            started_instant: started,
            container_sha256: container_sha
          )
        rescue ex : Error
          build_container_error_report(source_name, started, ex.message || ex.class.name, ex, container_sha)
        rescue ex : Exception
          wrapped = CorruptContainerError.new("Unhandled container error in #{source_name}: #{ex.message}")
          build_container_error_report(source_name, started, wrapped.message || "Corrupt container", wrapped, container_sha)
        ensure
          reader.close
        end
      end

      # Verifies a .bkl container from an open IO stream.
      def verify_io(io : IO, size : Int64? = nil, source_name : String = "<stream>") : VerificationReport
        started = Time.instant
        reader = Container::Reader.new(io, size, source_name)
        begin
          volumes = reader.read
          verify_volumes_internal(
            volumes: volumes,
            target_name: source_name,
            started_instant: started,
            container_sha256: nil
          )
        rescue ex : Error
          build_container_error_report(source_name, started, ex.message || ex.class.name, ex, nil)
        rescue ex : Exception
          wrapped = CorruptContainerError.new("Unhandled container error in #{source_name}: #{ex.message}")
          build_container_error_report(source_name, started, wrapped.message || "Corrupt container", wrapped, nil)
        ensure
          reader.close
        end
      end

      # Verifies a single mounted or in-memory Bakelite::Volume.
      def verify_volume(volume : Volume) : VerificationReport
        verify_volumes([volume], target_name: "volume:#{volume.name}")
      end

      # Verifies an array of Bakelite::Volume instances.
      def verify_volumes(
        volumes : Array(Volume),
        target_name : String = "<volumes>",
        container_sha256 : String? = nil,
      ) : VerificationReport
        verify_volumes_internal(
          volumes: volumes,
          target_name: target_name,
          started_instant: Time.instant,
          container_sha256: container_sha256
        )
      end

      # Verifies all visible union files across a Bakelite::FS::Registry.
      def verify_registry(registry : FS::Registry, target_name : String = "<registry>") : VerificationReport
        started = Time.instant
        target_vols = if vf = @volume_filter
                        registry.volumes.select { |v| v.name == vf }
                      else
                        registry.volumes
                      end
        verify_volumes_internal(
          volumes: target_vols,
          target_name: target_name,
          started_instant: started,
          container_sha256: nil,
          union_deduplicate: @volume_filter.nil?
        )
      end

      private def verify_volumes_internal(
        volumes : Array(Volume),
        target_name : String,
        started_instant : Time::Instant,
        container_sha256 : String?,
        union_deduplicate : Bool = false,
      ) : VerificationReport
        filtered_vols = if vf = @volume_filter
                          volumes.select { |v| v.name == vf }
                        else
                          volumes
                        end

        violations = [] of IntegrityViolation
        entries = [] of FileVerificationEntry
        manifest_map = Hash(String, String).new

        if filtered_vols.empty? && !@volume_filter.nil?
          violations << IntegrityViolation.new(
            kind: ViolationKind::CorruptContainer,
            message: "Requested volume ':#{@volume_filter}' not found in #{target_name}",
            volume_name: @volume_filter
          )
        end

        total_files = 0
        verified_files = 0
        total_chunks = 0
        verified_chunks = 0
        total_bytes = 0_i64
        seen_paths = Set(String).new
        seen_mounted_paths = Set(String).new
        mounted_entries = [] of FileVerificationEntry
        aborted = false

        filtered_vols.each do |vol|
          break if aborted
          sorted_keys = vol.items.keys.sort

          sorted_keys.each do |rel_key|
            break if aborted
            item = vol.items[rel_key]
            rel_path = Volume.normalize_path(item.path)
            mounted_path = if vol.mount_point.empty?
                             rel_path
                           else
                             "#{vol.mount_point}/#{rel_path}".strip('/')
                           end

            if union_deduplicate
              next unless seen_mounted_paths.add?(mounted_path)
            else
              seen_mounted_paths.add?(mounted_path)
            end
            seen_paths.add?(rel_path)

            total_files += 1
            item_chunks = item.is_a?(StoredItem) ? item.chunks.size : 1
            total_chunks += item_chunks

            entry, item_violations = verify_single_item(item, vol, rel_path, mounted_path)
            entries << entry
            if mounted_path != rel_path
              mounted_entries << FileVerificationEntry.new(
                path: mounted_path,
                volume_name: entry.volume_name,
                size: entry.size,
                actual_size: entry.actual_size,
                compressed_size: entry.compressed_size,
                crc32: entry.crc32,
                actual_crc32: entry.actual_crc32,
                sha256: entry.sha256,
                chunks_verified: entry.chunks_verified,
                valid: entry.valid,
                expected_sha256: entry.expected_sha256,
                error_message: entry.error_message
              )
            else
              mounted_entries << entry
            end

            verified_chunks += entry.chunks_verified
            total_bytes += entry.actual_size

            # Use mounted_path in union registry mode, or rel_path in volume/container mode
            canonical_key = union_deduplicate ? mounted_path : rel_path
            manifest_map[canonical_key] = entry.sha256

            if item_violations.empty?
              verified_files += 1
            else
              violations.concat(item_violations)
              if @fail_fast
                aborted = true
                break
              end
            end
          end
        end

        # Check required files (match either relative path or mounted path)
        unless aborted
          @required_files.each do |req_path|
            unless seen_paths.includes?(req_path) || seen_mounted_paths.includes?(req_path)
              violations << IntegrityViolation.new(
                kind: ViolationKind::MissingFile,
                path: req_path,
                expected: @expected_digests[req_path]? || "present",
                actual: "missing",
                message: "Required file '#{req_path}' is missing from archive"
              )
            end
          end

          # Strict manifest check: reject unexpected files not listed in expected_digests or required_files
          if @strict_manifest && (!@expected_digests.empty? || !@required_files.empty?)
            entries.each_with_index do |entry, idx|
              m_path = mounted_entries[idx].path
              allowed = @expected_digests.has_key?(entry.path) ||
                        @expected_digests.has_key?(m_path) ||
                        @required_files.includes?(entry.path) ||
                        @required_files.includes?(m_path)
              unless allowed
                violations << IntegrityViolation.new(
                  kind: ViolationKind::UnexpectedFile,
                  path: entry.path,
                  volume_name: entry.volume_name,
                  actual: entry.sha256,
                  message: "Unexpected file '#{entry.path}' not permitted by strict manifest policy"
                )
              end
            end
          end
        end

        # Sort entries & content_manifest deterministically by path
        canonical_entries = union_deduplicate ? mounted_entries : entries
        canonical_entries.sort_by!(&.path)

        sorted_manifest_map = Hash(String, String).new(initial_capacity: canonical_entries.size)
        canonical_entries.each do |e|
          sorted_manifest_map[e.path] = e.sha256
        end

        manifest_sha = self.class.compute_manifest_sha256(canonical_entries)
        alt_manifest_sha = if union_deduplicate
                             self.class.compute_manifest_sha256(entries)
                           else
                             self.class.compute_manifest_sha256(mounted_entries)
                           end

        if exp_manifest = @expected_manifest_sha256
          if manifest_sha != exp_manifest && alt_manifest_sha != exp_manifest
            violations << IntegrityViolation.new(
              kind: ViolationKind::ManifestDigestMismatch,
              expected: exp_manifest,
              actual: manifest_sha,
              message: "Archive manifest SHA-256 mismatch (expected #{exp_manifest}, got #{manifest_sha})"
            )
          elsif alt_manifest_sha == exp_manifest && manifest_sha != exp_manifest
            manifest_sha = alt_manifest_sha
          end
        end

        elapsed = (Time.instant - started_instant).total_seconds.round(6)
        report = VerificationReport.new(
          target_name: target_name,
          valid: violations.empty?,
          total_volumes: filtered_vols.size,
          total_files: total_files,
          verified_files: verified_files,
          total_chunks: total_chunks,
          verified_chunks: verified_chunks,
          total_bytes: total_bytes,
          manifest_sha256: manifest_sha,
          duration_seconds: elapsed,
          entries: canonical_entries,
          violations: violations,
          content_manifest: sorted_manifest_map,
          container_sha256: container_sha256
        )

        # Evaluate custom invariants
        @invariants.each do |inv_name, inv_proc|
          ok = begin
            inv_proc.call(report)
          rescue ex
            violations << IntegrityViolation.new(
              kind: ViolationKind::InvariantFailure,
              message: "Verification invariant '#{inv_name}' raised #{ex.class}: #{ex.message}"
            )
            false
          end
          unless ok
            if violations.none? { |v| v.kind.invariant_failure? && v.message.includes?(inv_name) }
              violations << IntegrityViolation.new(
                kind: ViolationKind::InvariantFailure,
                message: "Verification invariant '#{inv_name}' returned false"
              )
            end
          end
        end

        if !violations.empty? && report.valid
          report = VerificationReport.new(
            target_name: report.target_name,
            valid: false,
            total_volumes: report.total_volumes,
            total_files: report.total_files,
            verified_files: report.verified_files,
            total_chunks: report.total_chunks,
            verified_chunks: report.verified_chunks,
            total_bytes: report.total_bytes,
            manifest_sha256: report.manifest_sha256,
            duration_seconds: report.duration_seconds,
            entries: report.entries,
            violations: violations,
            content_manifest: report.content_manifest,
            container_sha256: report.container_sha256
          )
        end

        report
      end

      private def verify_single_item(
        item : Item,
        vol : Volume,
        rel_path : String,
        mounted_path : String,
      ) : Tuple(FileVerificationEntry, Array(IntegrityViolation))
        item_violations = [] of IntegrityViolation
        hasher = Digest::SHA256.new
        running_crc = Digest::CRC32.initial
        actual_size = 0_i64
        chunks_ok = 0

        if item.size < 0 || item.size > @max_decompressed_bytes
          item_violations << IntegrityViolation.new(
            kind: ViolationKind::SizeMismatch,
            path: rel_path,
            volume_name: vol.name,
            expected: "<= #{@max_decompressed_bytes}",
            actual: item.size.to_s,
            message: "File '#{rel_path}' size (#{item.size}) exceeds maximum allowed decompressed size (#{@max_decompressed_bytes})"
          )
        elsif item.is_a?(StoredItem) && @verify_chunks
          item.chunks.each_with_index do |chunk, chunk_idx|
            begin
              if (actual_size + chunk.uncompressed_size.to_i64) > @max_decompressed_bytes
                raise CorruptContainerError.new("Cumulative decompressed chunk size exceeds safety cap (#{@max_decompressed_bytes} bytes)")
              end

              raw_bytes = fetch_chunk_bytes(item, chunk)
              uncomp_bytes = decompress_chunk!(raw_bytes, item.compression, chunk.uncompressed_size)

              if uncomp_bytes.size.to_u32 != chunk.uncompressed_size
                item_violations << IntegrityViolation.new(
                  kind: ViolationKind::SizeMismatch,
                  path: rel_path,
                  volume_name: vol.name,
                  chunk_index: chunk_idx,
                  expected: chunk.uncompressed_size.to_s,
                  actual: uncomp_bytes.size.to_s,
                  message: "Chunk ##{chunk_idx} uncompressed size mismatch in '#{rel_path}'"
                )
              end

              chunk_actual_crc = Digest::CRC32.checksum(uncomp_bytes)
              if @verify_crc32 && chunk_actual_crc != chunk.crc32
                item_violations << IntegrityViolation.new(
                  kind: ViolationKind::ChunkCrc32Mismatch,
                  path: rel_path,
                  volume_name: vol.name,
                  chunk_index: chunk_idx,
                  expected: sprintf("%08x", chunk.crc32),
                  actual: sprintf("%08x", chunk_actual_crc),
                  message: "Chunk ##{chunk_idx} CRC32 mismatch in '#{rel_path}' (expected #{sprintf("%08x", chunk.crc32)}, got #{sprintf("%08x", chunk_actual_crc)})"
                )
              else
                chunks_ok += 1
              end

              running_crc = Digest::CRC32.update(uncomp_bytes, running_crc)
              hasher.update(uncomp_bytes)
              actual_size += uncomp_bytes.size.to_i64
            rescue ex : Exception
              item_violations << IntegrityViolation.new(
                kind: ViolationKind::CorruptContainer,
                path: rel_path,
                volume_name: vol.name,
                chunk_index: chunk_idx,
                message: "Chunk ##{chunk_idx} decompression/IO failure in '#{rel_path}': #{ex.message}"
              )
            end
          end
        else
          # Stream item via item.open in 64KB slices
          begin
            item.open do |stream|
              buffer = Bytes.new(65536)
              while (read_bytes = stream.read(buffer)) > 0
                actual_size += read_bytes.to_i64
                if actual_size > @max_decompressed_bytes
                  raise CorruptContainerError.new("Streamed file size exceeds safety cap (#{@max_decompressed_bytes} bytes)")
                end
                slice = buffer[0, read_bytes]
                running_crc = Digest::CRC32.update(slice, running_crc)
                hasher.update(slice)
              end
            end
            chunks_ok = item.is_a?(StoredItem) ? item.chunks.size : 1
          rescue ex : Exception
            item_violations << IntegrityViolation.new(
              kind: ViolationKind::CorruptContainer,
              path: rel_path,
              volume_name: vol.name,
              message: "Stream read failure in '#{rel_path}': #{ex.message}"
            )
          end
        end

        computed_sha256 = hasher.hexfinal

        # Verify file size matches metadata
        if actual_size != item.size && item_violations.none?(&.kind.corrupt_container?)
          item_violations << IntegrityViolation.new(
            kind: ViolationKind::SizeMismatch,
            path: rel_path,
            volume_name: vol.name,
            expected: item.size.to_s,
            actual: actual_size.to_s,
            message: "File size mismatch for '#{rel_path}' (expected #{item.size}, got #{actual_size})"
          )
        end

        # Verify file-level CRC32 matches metadata
        if @verify_crc32 && running_crc != item.crc32 && item_violations.none?(&.kind.corrupt_container?)
          item_violations << IntegrityViolation.new(
            kind: ViolationKind::FileCrc32Mismatch,
            path: rel_path,
            volume_name: vol.name,
            expected: item.crc32_hex,
            actual: sprintf("%08x", running_crc),
            message: "File CRC32 mismatch for '#{rel_path}' (expected #{item.crc32_hex}, got #{sprintf("%08x", running_crc)})"
          )
        end

        # Verify explicit expected CRC32 if registered
        if exp_crc = (@expected_crc32s[rel_path]? || @expected_crc32s[mounted_path]?)
          if running_crc != exp_crc
            item_violations << IntegrityViolation.new(
              kind: ViolationKind::FileCrc32Mismatch,
              path: rel_path,
              volume_name: vol.name,
              expected: sprintf("%08x", exp_crc),
              actual: sprintf("%08x", running_crc),
              message: "Expected CRC32 mismatch for '#{rel_path}' (expected #{sprintf("%08x", exp_crc)}, got #{sprintf("%08x", running_crc)})"
            )
          end
        end

        # Verify expected SHA-256 content address if registered
        exp_sha = @expected_digests[rel_path]? || @expected_digests[mounted_path]?
        if @verify_sha256 && exp_sha
          if computed_sha256 != exp_sha
            item_violations << IntegrityViolation.new(
              kind: ViolationKind::Sha256Mismatch,
              path: rel_path,
              volume_name: vol.name,
              expected: exp_sha,
              actual: computed_sha256,
              message: "SHA-256 content digest mismatch for '#{rel_path}' (expected #{exp_sha}, got #{computed_sha256})"
            )
          end
        end

        if item_violations.empty?
          item.sha256 = computed_sha256
        end

        entry = FileVerificationEntry.new(
          path: rel_path,
          volume_name: vol.name,
          size: item.size,
          actual_size: actual_size,
          compressed_size: item.compressed_size,
          crc32: item.crc32,
          actual_crc32: running_crc,
          sha256: computed_sha256,
          chunks_verified: chunks_ok,
          valid: item_violations.empty?,
          expected_sha256: exp_sha,
          error_message: item_violations.first?.try(&.message)
        )

        {entry, item_violations}
      end

      private def fetch_chunk_bytes(item : StoredItem, chunk : Chunk) : Bytes
        if data = chunk.data
          return data
        end

        if io = item.underlying_io
          buffer = Bytes.new(chunk.compressed_size)
          if io.is_a?(SynchronizedIO)
            io.read_at(chunk.offset, buffer)
          else
            if io.responds_to?(:seek)
              io.seek(chunk.offset, IO::Seek::Set)
            end
            io.read_fully(buffer)
          end
          return buffer
        end

        raise CorruptContainerError.new("Chunk has neither in-memory data nor underlying IO source")
      end

      private def decompress_chunk!(raw : Bytes, compression : CompressionType, expected_size : UInt32) : Bytes
        if expected_size.to_i64 > @max_decompressed_bytes
          raise CorruptContainerError.new("Chunk expected uncompressed size (#{expected_size}) exceeds safety cap")
        end

        case compression
        when CompressionType::None
          if raw.size.to_u32 != expected_size
            raise CorruptContainerError.new("Raw chunk byte length (#{raw.size}) does not match expected size (#{expected_size})")
          end
          raw
        when CompressionType::Deflate
          memory_in = IO::Memory.new(raw, writable: false)
          Compress::Deflate::Reader.open(memory_in) do |deflate|
            buf = Bytes.new(expected_size)
            deflate.read_fully(buf)
            buf
          end
        when CompressionType::Zlib
          memory_in = IO::Memory.new(raw, writable: false)
          Compress::Zlib::Reader.open(memory_in) do |zlib|
            buf = Bytes.new(expected_size)
            zlib.read_fully(buf)
            buf
          end
        when CompressionType::Gzip
          memory_in = IO::Memory.new(raw, writable: false)
          Compress::Gzip::Reader.open(memory_in) do |gzip|
            buf = Bytes.new(expected_size)
            gzip.read_fully(buf)
            buf
          end
        else
          raw
        end
      rescue ex : Error
        raise ex
      rescue ex : Exception
        raise CorruptContainerError.new("Failed to decompress #{compression} chunk: #{ex.message}")
      end

      private def compute_file_sha256(path : Path) : String?
        hasher = Digest::SHA256.new
        File.open(path, "rb") do |file|
          buffer = Bytes.new(65536)
          while (n = file.read(buffer)) > 0
            hasher.update(buffer[0, n])
          end
        end
        hasher.hexfinal
      rescue
        nil
      end

      private def build_container_error_report(
        target_name : String,
        started : Time::Instant,
        message : String,
        ex : Exception,
        container_sha : String? = nil,
      ) : VerificationReport
        elapsed = (Time.instant - started).total_seconds.round(6)
        violation = IntegrityViolation.new(
          kind: ViolationKind::CorruptContainer,
          message: message
        )
        empty_entries = [] of FileVerificationEntry
        VerificationReport.new(
          target_name: target_name,
          valid: false,
          total_volumes: 0,
          total_files: 0,
          verified_files: 0,
          total_chunks: 0,
          verified_chunks: 0,
          total_bytes: 0_i64,
          manifest_sha256: self.class.compute_manifest_sha256(empty_entries),
          duration_seconds: elapsed,
          entries: empty_entries,
          violations: [violation],
          content_manifest: {} of String => String,
          container_sha256: container_sha,
          root_exception: ex
        )
      end
    end
  end
end
