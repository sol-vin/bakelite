require "./spec_helper"

describe "Bakelite: Compile-Time Transforms & Caching" do
  it "applies built-in pure Crystal transformations" do
    # 1. CRLF to LF
    windows_text = "line1\r\nline2\r\nline3\r\n"
    unix_text = Bakelite::Transform::Builtins.apply(:crlf_to_lf, windows_text)
    unix_text.should eq("line1\nline2\nline3\n")

    # 2. Minify JSON
    formatted_json = "{\n  \"name\": \"bakelite\",\n  \"active\": true\n}"
    minified = Bakelite::Transform::Builtins.apply(:minify_json, formatted_json)
    minified.should eq("{\"name\":\"bakelite\",\"active\":true}")

    # 3. Strip Comments
    commented_code = <<-TEXT
    # This is a header comment
    server:
      port: 8080 # comment
      // double slash comment
      host: "localhost"
    TEXT
    stripped = Bakelite::Transform::Builtins.apply(:strip_comments, commented_code)
    stripped.includes?("# This is a header comment").should be_false
    stripped.includes?("// double slash comment").should be_false
    stripped.includes?("port: 8080").should be_true

    # 4. Trim
    padded = "   \n\t Hello Bakelite! \t\n   "
    Bakelite::Transform::Builtins.apply(:trim, padded).should eq("Hello Bakelite!")
  end

  it "manages content-addressed caching in .bakelite/cache" do
    temp_cache_dir = BakeliteSpecHelper.temp_dir.join("test_cache")
    cache = Bakelite::Transform::Cache.new(temp_cache_dir)

    begin
      input_data = "shader_source_code_vec4_color"
      command_spec = "glslc %IN% -o %OUT%"

      key = cache.compute_key(input_data, command_spec)
      key.size.should eq(64) # SHA256 hex string

      cache.has_key?(key).should be_false
      cache.get?(key).should be_nil

      # Write to cache
      transformed_output = Bytes[0x03, 0x02, 0x23, 0x07] # SPIR-V magic bytes
      cache.put(key, transformed_output)

      # Check cache hit
      cache.has_key?(key).should be_true
      cached_result = cache.get?(key)
      cached_result.should_not be_nil
      cached_result.should eq(transformed_output)
    ensure
      BakeliteSpecHelper.cleanup(temp_cache_dir)
    end
  end
end
