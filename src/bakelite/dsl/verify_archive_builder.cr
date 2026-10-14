require "../core/integrity_verifier"

module Bakelite
  module DSL
    alias VerificationTarget = Path | String | Bytes | IO | Volume | FS::Registry | Array(Volume)

    # Tier 2 Declarative Builder for configuring and running Bakelite.verify_archive.
    # Wraps Bakelite::Core::IntegrityVerifier in a fluent block receiver DSL.
    class VerifyArchiveBuilder
      getter verifier : Core::IntegrityVerifier
      property target_source : VerificationTarget?
      property raise_on_error : Bool

      def initialize(
        @target_source : VerificationTarget? = nil,
        @raise_on_error : Bool = false,
      )
        @verifier = Core::IntegrityVerifier.new
      end

      # Sets the target archive, byte slice, stream, volume, or registry to verify.
      def archive(source : VerificationTarget) : self
        @target_source = source
        self
      end

      def target(source : VerificationTarget) : self
        @target_source = source
        self
      end

      def source(source : VerificationTarget) : self
        @target_source = source
        self
      end

      def bytes(slice : Bytes) : self
        @target_source = slice
        self
      end

      def registry(reg : FS::Registry) : self
        @target_source = reg
        self
      end

      # Filters verification to a specific volume name, or sets a Volume instance as the target.
      def volume(vol : Volume) : self
        @target_source = vol
        self
      end

      def volume(name : Symbol | String) : self
        @verifier.volume_filter = name.to_s
        self
      end

      def verify_crc32(val : Bool = true) : self
        @verifier.verify_crc32 = val
        self
      end

      def verify_chunks(val : Bool = true) : self
        @verifier.verify_chunks = val
        self
      end

      def verify_sha256(val : Bool = true) : self
        @verifier.verify_sha256 = val
        self
      end

      def strict(val : Bool = true) : self
        @verifier.strict_manifest = val
        self
      end

      def strict_manifest(val : Bool = true) : self
        @verifier.strict_manifest = val
        self
      end

      def fail_fast(val : Bool = true) : self
        @verifier.fail_fast = val
        self
      end

      def raise_on_error(val : Bool = true) : self
        @raise_on_error = val
        self
      end

      def assert_valid(val : Bool = true) : self
        @raise_on_error = val
        self
      end

      def assert_clean(val : Bool = true) : self
        @raise_on_error = val
        self
      end

      def max_decompressed_bytes(bytes : Int64 | Int32) : self
        @verifier.max_decompressed_bytes = bytes.to_i64
        self
      end

      # Declares an expected SHA-256 hex digest for a specific virtual file path.
      def expect_sha256(path : String, sha256 : String) : self
        @verifier.expect_digest(path, sha256)
        self
      end

      def expect_digest(path : String, sha256 : String) : self
        @verifier.expect_digest(path, sha256)
        self
      end

      def digest(path : String, sha256 : String) : self
        @verifier.expect_digest(path, sha256)
        self
      end

      # Declares an expected CRC32 checksum for a specific virtual file path.
      def expect_crc32(path : String, crc32 : UInt32) : self
        @verifier.expect_crc32(path, crc32)
        self
      end

      # Declares a map of expected virtual file paths to SHA-256 hex digests.
      def expect_manifest(digests : Hash(String, String), strict : Bool = false) : self
        @verifier.expect_manifest(digests, strict: strict)
        self
      end

      def expect_manifest(manifest : Core::ArchiveManifest, strict : Bool = true) : self
        @verifier.expect_manifest(manifest, strict: strict)
        self
      end

      def manifest(digests : Hash(String, String), strict : Bool = false) : self
        @verifier.expect_manifest(digests, strict: strict)
        self
      end

      def manifest(manifest : Core::ArchiveManifest, strict : Bool = true) : self
        @verifier.expect_manifest(manifest, strict: strict)
        self
      end

      # Declares the expected deterministic SHA-256 manifest digest of the entire archive/volume.
      def expect_manifest_sha256(digest : String) : self
        @verifier.expect_manifest_sha256(digest)
        self
      end

      def manifest_sha256(digest : String) : self
        @verifier.expect_manifest_sha256(digest)
        self
      end

      def signature(digest : String) : self
        @verifier.expect_manifest_sha256(digest)
        self
      end

      # Declares one or more required virtual file paths that must exist in the archive.
      def require_file(path : String) : self
        @verifier.require_file(path)
        self
      end

      def require_files(*paths : String) : self
        paths.each { |p| @verifier.require_file(p) }
        self
      end

      def require_files(paths : Enumerable(String)) : self
        @verifier.require_files(paths)
        self
      end

      # Registers a custom verification invariant predicate.
      def invariant(name : String = "invariant_#{@verifier.invariants.size + 1}", &block : Core::VerificationReport -> Bool) : self
        @verifier.add_invariant(name, &block)
        self
      end

      def assert_invariant(name : String = "invariant_#{@verifier.invariants.size + 1}", &block : Core::VerificationReport -> Bool) : self
        @verifier.add_invariant(name, &block)
        self
      end

      def build : Core::IntegrityVerifier
        @verifier
      end

      def run : Core::VerificationReport
        effective_target = @target_source || ::Bakelite.fs
        report = @verifier.verify(effective_target)
        report.assert_valid! if @raise_on_error
        report
      end
    end
  end

  class Volume
    # Verifies the SHA-256 and CRC32 integrity of all items in this volume.
    def verify_archive(
      raise_on_error : Bool = false,
      expected_digests : Hash(String, String)? = nil,
      expected_manifest_sha256 : String? = nil,
      strict : Bool = false,
    ) : Core::VerificationReport
      verifier = Core::IntegrityVerifier.new(strict_manifest: strict)
      verifier.expect_manifest(expected_digests, strict: strict) if expected_digests
      verifier.expect_manifest_sha256(expected_manifest_sha256) if expected_manifest_sha256
      report = verifier.verify_volume(self)
      report.assert_valid! if raise_on_error
      report
    end

    def verify_archive(raise_on_error : Bool = false, &) : Core::VerificationReport
      builder = DSL::VerifyArchiveBuilder.new(self, raise_on_error: raise_on_error)
      with builder yield builder
      builder.run
    end

    def verify_archive! : Core::VerificationReport
      verify_archive(raise_on_error: true)
    end

    def verify_archive!(&) : Core::VerificationReport
      verify_archive(raise_on_error: true) do |v|
        with v yield v
      end
    end
  end

  module FS
    class Registry
      # Verifies the SHA-256 and CRC32 integrity of all visible items in this registry.
      def verify_archive(
        raise_on_error : Bool = false,
        expected_digests : Hash(String, String)? = nil,
        expected_manifest_sha256 : String? = nil,
        strict : Bool = false,
      ) : Core::VerificationReport
        verifier = Core::IntegrityVerifier.new(strict_manifest: strict)
        verifier.expect_manifest(expected_digests, strict: strict) if expected_digests
        verifier.expect_manifest_sha256(expected_manifest_sha256) if expected_manifest_sha256
        report = verifier.verify_registry(self)
        report.assert_valid! if raise_on_error
        report
      end

      def verify_archive(raise_on_error : Bool = false, &) : Core::VerificationReport
        builder = DSL::VerifyArchiveBuilder.new(self, raise_on_error: raise_on_error)
        with builder yield builder
        builder.run
      end

      def verify_archive! : Core::VerificationReport
        verify_archive(raise_on_error: true)
      end

      def verify_archive!(&) : Core::VerificationReport
        verify_archive(raise_on_error: true) do |v|
          with v yield v
        end
      end
    end
  end
end
