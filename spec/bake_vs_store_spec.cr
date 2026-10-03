require "./spec_helper"

describe "Bakelite: Bake vs Store Semantics" do
  it "bakes inlined static strings with zero-copy and instant access" do
    content = "name: lapis\nversion: 0.1.0\n"
    baked = Bakelite::BakedItem.from_string("shard.yml", :root, content)

    baked.storage_mode.should eq(Bakelite::StorageMode::Bake)
    baked.path.should eq("shard.yml")
    baked.volume_name.should eq("root")
    baked.size.should eq(content.bytesize.to_i64)
    baked.compressed_size.should eq(content.bytesize.to_i64)
    baked.content.should eq(content)
    baked.to_s.should eq(content)
    baked.to_slice.should eq(content.to_slice)
    baked.mime_type.should eq("application/yaml")

    # Opening stream returns IO::Memory
    stream = baked.open
    stream.is_a?(IO::Memory).should be_true
    stream.gets_to_end.should eq(content)
    stream.close
  end

  it "stores chunked, compressed assets and streams them via FileIO" do
    raw_data = "This is a streamable sound bank entry with repeated audio pattern data! " * 50
    bytes = raw_data.to_slice
    chunks = Bakelite::Chunker.chunk_data(bytes, chunk_size: 128_u32, compression: Bakelite::CompressionType::Deflate)

    chunks.size.should be > 1

    stored = Bakelite::StoredItem.new(
      path: "audio/sfx.wav",
      volume_name: :audio,
      size: bytes.size.to_i64,
      compressed_size: chunks.sum(&.compressed_size.to_i64),
      chunks: chunks,
      compression: Bakelite::CompressionType::Deflate,
      crc32: Digest::CRC32.checksum(bytes)
    )

    stored.storage_mode.should eq(Bakelite::StorageMode::Store)
    stored.volume_name.should eq("audio")
    stored.size.should eq(bytes.size.to_i64)
    stored.compressed_size.should be < bytes.size.to_i64
    stored.mime_type.should eq("audio/wav")

    # Opens as Bakelite::FileIO
    stream = stored.open
    stream.is_a?(Bakelite::FileIO).should be_true
    stream.gets_to_end.should eq(raw_data)
    stream.close

    # to_s and to_slice match original bytes
    stored.to_s.should eq(raw_data)
    stored.to_slice.should eq(bytes)
    stored.etag.should contain(stored.crc32_hex)
  end
end
