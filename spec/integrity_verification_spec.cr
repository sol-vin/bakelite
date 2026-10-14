require "./spec_helper"
require "crowbar"
require "digest/sha256"
require "digest/crc32"

describe "Bakelite: Deterministic SHA-256 Content Addressing & Archive Verification" do
  describe "Item, Volume & Registry SHA-256 Content Addressing" do
    it "computes and caches deterministic SHA-256 digests for BakedItem and StoredItem" do
      payload_str = "Deterministic content-addressed asset payload in Bakelite!"
      expected_sha = Digest::SHA256.hexdigest(payload_str)
      expected_crc = Digest::CRC32.checksum(payload_str.to_slice)

      baked = Bakelite::BakedItem.from_string("config/settings.json", :root, payload_str)
      baked.sha256.should eq(expected_sha)
      baked.content_address.should eq("sha256:#{expected_sha}")
      baked.strong_etag.should eq("\"sha256-#{expected_sha}\"")
      baked.sha256_bytes.should eq(expected_sha.hexbytes)
      baked.verify_sha256?(expected_sha).should be_true
      baked.verify_sha256?("sha256:#{expected_sha.upcase}").should be_true
      baked.verify_sha256?("0" * 64).should be_false
      baked.verify_crc32?.should be_true

      # Multi-chunk StoredItem with Deflate compression
      chunks = Bakelite::Chunker.chunk_data(
        payload_str.to_slice,
        chunk_size: 16_u32,
        compression: Bakelite::CompressionType::Deflate
      )
      stored = Bakelite::StoredItem.new(
        path: "data/stream.bin",
        volume_name: :assets,
        size: payload_str.bytesize.to_i64,
        compressed_size: chunks.sum(&.compressed_size.to_i64),
        chunks: chunks,
        compression: Bakelite::CompressionType::Deflate,
        crc32: expected_crc
      )

      stored.chunks.size.should be > 3
      stored.sha256.should eq(expected_sha)
      stored.content_address.should eq("sha256:#{expected_sha}")
      stored.verify_sha256?(expected_sha).should be_true
      stored.verify_crc32?.should be_true
    end

    it "produces order-independent deterministic volume manifests and binary containers" do
      file_a = {"alpha/first.txt", "Alpha file content 12345"}
      file_b = {"beta/second.json", %({"key": "beta_value", "count": 42})}
      file_c = {"gamma/third.bin", String.new(Bytes.new(1024) { |i| ((i * 73 + 19) & 0xFF).to_u8 })}

      vol_forward = Bakelite::Volume.new(:deterministic, mount_point: "det")
      vol_forward.add(Bakelite::BakedItem.from_string(file_a[0], :deterministic, file_a[1]))
      vol_forward.add(Bakelite::BakedItem.from_string(file_b[0], :deterministic, file_b[1]))
      vol_forward.add(Bakelite::BakedItem.from_string(file_c[0], :deterministic, file_c[1]))

      vol_reverse = Bakelite::Volume.new(:deterministic, mount_point: "det")
      vol_reverse.add(Bakelite::BakedItem.from_string(file_c[0], :deterministic, file_c[1]))
      vol_reverse.add(Bakelite::BakedItem.from_string(file_b[0], :deterministic, file_b[1]))
      vol_reverse.add(Bakelite::BakedItem.from_string(file_a[0], :deterministic, file_a[1]))

      # Manifest map and manifest_sha256 must be identical regardless of insertion order
      vol_forward.content_manifest.keys.should eq(["alpha/first.txt", "beta/second.json", "gamma/third.bin"])
      vol_forward.content_manifest.should eq(vol_reverse.content_manifest)
      vol_forward.manifest_sha256.should eq(vol_reverse.manifest_sha256)
      vol_forward.content_address.should eq(vol_reverse.content_address)

      # Binary container slices packed from both volumes must be byte-for-byte identical
      bytes_forward = Bakelite.pack_to_slice([vol_forward])
      bytes_reverse = Bakelite.pack_to_slice([vol_reverse])
      bytes_forward.should eq(bytes_reverse)
      Digest::SHA256.hexdigest(bytes_forward).should eq(Digest::SHA256.hexdigest(bytes_reverse))

      # Content-addressable lookups on Volume
      sha_b = Digest::SHA256.hexdigest(file_b[1])
      vol_forward.has_sha256?(sha_b).should be_true
      vol_forward.has_sha256?("sha256:#{sha_b}").should be_true
      found = vol_forward.get_by_sha256(sha_b)
      found.path.should eq("beta/second.json")
      found.content.should eq(file_b[1])

      expect_raises(KeyError) do
        vol_forward.get_by_sha256("f" * 64)
      end
    end

    it "supports content-addressable lookup and priority shadowing in FS::Registry" do
      reg = Bakelite::FS::Registry.new

      base_vol = Bakelite::Volume.new(:base, mount_point: "app", priority: 10)
      base_vol.add(Bakelite::BakedItem.from_string("config.json", :base, %({"env": "base"})))
      base_vol.add(Bakelite::BakedItem.from_string("readme.txt", :base, "Base Readme"))

      overlay_vol = Bakelite::Volume.new(:overlay, mount_point: "app", priority: 50)
      overlay_vol.add(Bakelite::BakedItem.from_string("config.json", :overlay, %({"env": "production"})))

      reg.mount(base_vol)
      reg.mount(overlay_vol)

      prod_sha = Digest::SHA256.hexdigest(%({"env": "production"}))
      base_sha = Digest::SHA256.hexdigest(%({"env": "base"}))
      readme_sha = Digest::SHA256.hexdigest("Base Readme")

      manifest = reg.content_manifest
      manifest["app/config.json"].should eq(prod_sha)
      manifest["app/readme.txt"].should eq(readme_sha)

      reg.has_sha256?(prod_sha).should be_true
      # Base config is shadowed by higher-priority overlay volume
      reg.has_sha256?(base_sha).should be_false
      reg.get_by_sha256(readme_sha).content.should eq("Base Readme")
    end
  end

  describe "Tier 1 (Bakelite::Core::IntegrityVerifier) & Tier 2 (Bakelite.verify_archive)" do
    it "verifies a packed .bkl archive with declarative SHA-256 and manifest expectations" do
      temp_dir = BakeliteSpecHelper.temp_dir
      src_dir = temp_dir.join("src_assets")
      archive_path = temp_dir.join("verified_bundle.bkl")

      begin
        FileUtils.mkdir_p(src_dir.join("shaders"))
        shader_code = "void fragment() { COLOR = vec4(1.0, 0.5, 0.2, 1.0); }"
        manifest_json = %({"title": "Sol-Vin Engine", "version": "1.0.0"})
        binary_blob = BakeliteSpecHelper.generate_synthetic_file(src_dir.join("data.bin"), 40_000)

        File.write(src_dir.join("shaders/toon.gdshader"), shader_code)
        File.write(src_dir.join("manifest.json"), manifest_json)

        shader_sha = Digest::SHA256.hexdigest(shader_code)
        json_sha = Digest::SHA256.hexdigest(manifest_json)
        blob_sha = Digest::SHA256.hexdigest(binary_blob)

        Bakelite.pack(
          target: archive_path,
          source_dir: src_dir,
          volume: :bundle,
          mount_point: "bundle",
          chunk_size: 8192_u32,
          compression: Bakelite::CompressionType::Deflate,
          append: false
        )

        # First pass: inspect verification report and obtain canonical manifest digest
        initial_report = Bakelite.verify_archive!(archive_path)
        initial_report.valid?.should be_true
        initial_report.clean?.should be_true
        initial_report.total_volumes.should eq(1)
        initial_report.total_files.should eq(3)
        initial_report.verified_files.should eq(3)
        initial_report.verified_chunks.should be >= 7
        initial_report.sha256_for("shaders/toon.gdshader").should eq(shader_sha)
        initial_report.sha256_for("manifest.json").should eq(json_sha)
        initial_report.sha256_for("data.bin").should eq(blob_sha)

        exported_manifest = initial_report.to_manifest
        exported_manifest["shaders/toon.gdshader"].should eq(shader_sha)

        # Second pass: verify using Tier 2 declarative DSL block
        report = Bakelite.verify_archive!(archive_path) do |v|
          v.volume :bundle
          v.strict true
          v.verify_chunks true
          v.verify_crc32 true
          v.verify_sha256 true
          v.expect_sha256 "shaders/toon.gdshader", shader_sha
          v.expect_sha256 "manifest.json", "sha256:#{json_sha}"
          v.expect_sha256 "data.bin", blob_sha
          v.expect_manifest_sha256 exported_manifest.manifest_sha256
          v.require_files "shaders/toon.gdshader", "manifest.json", "data.bin"
          v.assert_invariant("positive_total_bytes") do |rep|
            rep.total_bytes == (shader_code.bytesize + manifest_json.bytesize + binary_blob.size)
          end
        end

        report.valid?.should be_true
        report.manifest_sha256.should eq(exported_manifest.manifest_sha256)
        report.to_markdown.should contain("[Bakelite Archive Integrity: PASS]")
        JSON.parse(report.to_json)["valid"].as_bool.should be_true
      ensure
        BakeliteSpecHelper.cleanup(temp_dir)
      end
    end

    it "detects SHA-256 content mismatches, missing files, unexpected strict files, and chunk corruption" do
      vol = Bakelite::Volume.new(:sec_vol)
      chunks = Bakelite::Chunker.chunk_data(
        "Sensitive payload data that must not be tampered with".to_slice,
        chunk_size: 16_u32,
        compression: Bakelite::CompressionType::None
      )
      crc = Digest::CRC32.checksum("Sensitive payload data that must not be tampered with".to_slice)
      vol.add(Bakelite::StoredItem.new(
        path: "secret.txt",
        volume_name: :sec_vol,
        size: 53_i64,
        compressed_size: 53_i64,
        chunks: chunks,
        compression: Bakelite::CompressionType::None,
        crc32: crc
      ))
      vol.add(Bakelite::BakedItem.from_string("extra.txt", :sec_vol, "Extra file"))

      archive_bytes = Bakelite.pack_to_slice([vol])

      # 1. Wrong expected SHA-256 digest
      bad_sha_report = Bakelite.verify_archive(archive_bytes) do |v|
        v.expect_sha256 "secret.txt", "0" * 64
      end
      bad_sha_report.valid?.should be_false
      bad_sha_report.violations.any?(&.kind.sha256_mismatch?).should be_true

      expect_raises(Bakelite::IntegrityError, /SHA-256 content digest mismatch/) do
        bad_sha_report.assert_valid!
      end

      # 2. Missing required file
      missing_report = Bakelite.verify_archive(archive_bytes) do |v|
        v.require_file "non_existent.txt"
      end
      missing_report.valid?.should be_false
      missing_report.violations.any?(&.kind.missing_file?).should be_true

      # 3. Unexpected file in strict manifest mode
      strict_report = Bakelite.verify_archive(archive_bytes) do |v|
        v.strict true
        v.expect_sha256 "secret.txt", Digest::SHA256.hexdigest("Sensitive payload data that must not be tampered with")
      end
      strict_report.valid?.should be_false
      strict_report.violations.any?(&.kind.unexpected_file?).should be_true

      # 4. Tamper with a single byte inside a chunk payload in the binary container
      tampered = archive_bytes.dup
      # Locate "Sensitive" in the raw uncompressed chunk payload and flip a bit
      idx = String.new(tampered).index("Sensitive").not_nil!
      tampered[idx] = tampered[idx] ^ 0x01_u8

      tampered_report = Bakelite.verify_archive(tampered)
      tampered_report.valid?.should be_false
      tampered_report.violations.any?(&.kind.chunk_crc32_mismatch?).should be_true
      tampered_report.violations.any?(&.kind.file_crc32_mismatch?).should be_true

      expect_raises(Bakelite::IntegrityError) do
        Bakelite.verify_archive!(tampered)
      end
    end

    it "verifies mounted volumes, FS::Registry instances, and reusable verifiers via define_archive_verifier" do
      reg = Bakelite::FS::Registry.new
      vol = Bakelite::Volume.new(:ui, mount_point: "ui", priority: 10)
      vol.add(Bakelite::BakedItem.from_string("style.css", :ui, "body { background: #111; }"))
      vol.add(Bakelite::BakedItem.from_string("app.js", :ui, "console.log('bakelite');"))
      reg.mount(vol)

      vol_report = vol.verify_archive! do |v|
        v.expect_manifest_sha256 vol.manifest_sha256
      end
      vol_report.valid?.should be_true
      vol_report.verified_files.should eq(2)

      reg_report = reg.verify_archive! do |v|
        v.expect_manifest_sha256 reg.manifest_sha256
        v.require_files "ui/style.css", "ui/app.js"
      end
      reg_report.valid?.should be_true
      reg_report.manifest_sha256.should eq(reg.manifest_sha256)

      reusable = Bakelite.define_archive_verifier do |v|
        v.strict true
        v.expect_sha256 "style.css", Digest::SHA256.hexdigest("body { background: #111; }")
        v.expect_sha256 "app.js", Digest::SHA256.hexdigest("console.log('bakelite');")
      end
      reusable.verify!(vol).valid?.should be_true
    end
  end

  describe "Crowbar.corpus_gate Fuzzing & Regression Gate" do
    it "fuzz-tests Bakelite.verify_archive across multi-compression container corpora within a 60s watchdog budget" do
      # Construct deterministic baseline container seeds covering Deflate, Zlib, Gzip, and None
      make_container_seed = ->(comp : Bakelite::CompressionType, chunk_sz : UInt32) : Bytes {
        v = Bakelite::Volume.new(:fuzz_vol, mount_point: "fuzz", default_chunk_size: chunk_sz, default_compression: comp)
        p1 = "Header: Bakelite Deterministic Content Addressing Test Payload #1\n" * 4
        p2 = %({"manifest": true, "compression": "#{comp}", "items": [1, 2, 3, 4, 5]})

        c1 = Bakelite::Chunker.chunk_data(p1.to_slice, chunk_size: chunk_sz, compression: comp)
        v.add(Bakelite::StoredItem.new(
          path: "docs/readme.txt",
          volume_name: :fuzz_vol,
          size: p1.bytesize.to_i64,
          compressed_size: c1.sum(&.compressed_size.to_i64),
          chunks: c1,
          compression: comp,
          crc32: Digest::CRC32.checksum(p1.to_slice)
        ))

        c2 = Bakelite::Chunker.chunk_data(p2.to_slice, chunk_size: chunk_sz, compression: comp)
        v.add(Bakelite::StoredItem.new(
          path: "config/app.json",
          volume_name: :fuzz_vol,
          size: p2.bytesize.to_i64,
          compressed_size: c2.sum(&.compressed_size.to_i64),
          chunks: c2,
          compression: comp,
          crc32: Digest::CRC32.checksum(p2.to_slice)
        ))

        Bakelite.pack_to_slice([v])
      }

      seed_deflate = make_container_seed.call(Bakelite::CompressionType::Deflate, 64_u32)
      seed_zlib = make_container_seed.call(Bakelite::CompressionType::Zlib, 64_u32)
      seed_gzip = make_container_seed.call(Bakelite::CompressionType::Gzip, 128_u32)
      seed_raw = make_container_seed.call(Bakelite::CompressionType::None, 64_u32)

      # Verify all 4 baseline seeds pass verification before fuzzing
      baseline_digests = Hash(String, String).new
      [seed_deflate, seed_zlib, seed_gzip, seed_raw].each do |seed_bytes|
        rep = Bakelite.verify_archive!(seed_bytes)
        rep.valid?.should be_true
        baseline_digests[Digest::SHA256.hexdigest(seed_bytes)] = rep.manifest_sha256
      end

      # Craft adversarial edge-case reproducers (truncated trailer, bogus counts, bad magic)
      reproducer_tiny = Bytes.new(12, 0x41_u8)
      reproducer_bad_magic = seed_deflate.dup.tap { |b| 8.times { |i| b[i] = 0x00_u8 } }
      reproducer_huge_index_offset = seed_deflate.dup.tap do |b|
        # Overwrite index_offset in trailer with 0xFFFFFFFFFFFFFFFF
        trailer_start = b.size - 32
        8.times { |i| b[trailer_start + 8 + i] = 0xFF_u8 }
      end

      gate_report = Crowbar.corpus_gate("Bakelite.verify_archive Binary Container Fuzz Gate") do |gate|
        gate.watchdog_budget 60.seconds
        gate.timeout 500.milliseconds
        gate.seed 0xBA4E117E_u64
        gate.seeds 101_u64, 202_u64, 303_u64, 404_u64
        gate.iterations 32
        gate.mutations_per_seed 4
        gate.verify_determinism true

        gate.corpus seed_deflate, id: "bkl_deflate"
        gate.corpus seed_zlib, id: "bkl_zlib"
        gate.corpus seed_gzip, id: "bkl_gzip"
        gate.corpus seed_raw, id: "bkl_raw"

        gate.reproducer reproducer_tiny, id: "adv_tiny_file"
        gate.reproducer reproducer_bad_magic, id: "adv_bad_header_magic"
        gate.reproducer reproducer_huge_index_offset, id: "adv_huge_index_offset"

        # Expected structured Bakelite exceptions when calling strict verify_archive!
        gate.expected_errors Bakelite::Error

        gate.execute do |buf|
          slice = buf.to_slice
          # 1. Non-throwing verification must never raise an unhandled exception on any mutant
          report = Bakelite.verify_archive(slice)

          # 2. If the mutant matches one of our known valid baselines, it must be valid
          buf_sha = Digest::SHA256.hexdigest(slice)
          if exp_manifest = baseline_digests[buf_sha]?
            report.valid?.should be_true
            report.manifest_sha256.should eq(exp_manifest)
          end

          # 3. Strict verification must either succeed (for valid containers) or raise a typed Bakelite::Error
          Bakelite.verify_archive!(slice)
        end

        gate.assert_invariant("manifest_sha256_is_always_64_hex_chars") do |buf|
          rep = Bakelite.verify_archive(buf.to_slice)
          rep.manifest_sha256.matches?(/\A[0-9a-f]{64}\z/)
        end
      end

      gate_report.clean?.should be_true
      gate_report.within_budget?.should be_true
      gate_report.failures.should eq(0)
      gate_report.timeouts.should eq(0)
      gate_report.total_executions.should be >= 50
    end

    it "fuzz-tests interior payload & index mutations while preserving 32-byte BKLEND trailer via Crowbar scopes" do
      vol = Bakelite::Volume.new(:scoped_fuzz, default_chunk_size: 32_u32)
      payload = "Bakelite interior chunk & index mutation test payload!" * 3
      chunks = Bakelite::Chunker.chunk_data(payload.to_slice, chunk_size: 32_u32, compression: Bakelite::CompressionType::Deflate)
      vol.add(Bakelite::StoredItem.new(
        path: "asset.txt",
        volume_name: :scoped_fuzz,
        size: payload.bytesize.to_i64,
        compressed_size: chunks.sum(&.compressed_size.to_i64),
        chunks: chunks,
        compression: Bakelite::CompressionType::Deflate,
        crc32: Digest::CRC32.checksum(payload.to_slice)
      ))

      container_bytes = Bakelite.pack_to_slice([vol])
      expected_manifest_sha = vol.manifest_sha256
      interior_end = container_bytes.size - 33

      gate_report = Crowbar.corpus_gate("Bakelite Interior Payload & Index Scoped Fuzz Gate") do |gate|
        gate.watchdog_budget 60.seconds
        gate.timeout 500.milliseconds
        gate.seed 0x1337C0DE_u64
        gate.iterations 25
        gate.corpus container_bytes, id: "scoped_bkl_seed", mutations: 5

        # Mutate only the interior body (preserving the 8-byte BAKELITE header and 32-byte BKLEND trailer)
        gate.scope(:interior_body, bytes: 8..interior_end) do |s|
          s.mutate(:byte_flip, :bit_flip_run, :arithmetic)
        end

        gate.expected_errors Bakelite::Error

        gate.execute do |buf|
          slice = buf.to_slice
          if slice == container_bytes
            rep = Bakelite.verify_archive!(slice, expected_manifest_sha256: expected_manifest_sha)
            rep.valid?.should be_true
          else
            # Any interior mutation that alters the archive must either fail verification or raise Bakelite::Error
            rep = Bakelite.verify_archive(slice, expected_manifest_sha256: expected_manifest_sha)
            if rep.valid?
              # If valid, the unmutated content digest must still match 100%
              rep.manifest_sha256.should eq(expected_manifest_sha)
            end
          end
        end
      end

      gate_report.clean?.should be_true
      gate_report.within_budget?.should be_true
    end
  end
end
