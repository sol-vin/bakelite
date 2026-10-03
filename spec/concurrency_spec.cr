require "./spec_helper"

describe "Bakelite: Concurrency and Thread Safety" do
  it "supports concurrent reads across multiple fibers on the same container" do
    temp_dir = BakeliteSpecHelper.temp_dir
    src_data = temp_dir.join("concurrent_src")
    container = temp_dir.join("concurrent.bkl")

    begin
      FileUtils.mkdir_p(src_data)
      File.write(src_data.join("file_a.txt"), "Alfa " * 5000)
      File.write(src_data.join("file_b.txt"), "Bravo " * 5000)
      File.write(src_data.join("file_c.txt"), "Charlie " * 5000)

      writer = Bakelite::Container::Writer.new(container)
      writer.pack_directory(src_data, volume_name: :assets)
      writer.write(append: false)

      reader = Bakelite::Container::Reader.new(container)
      volumes = reader.read
      vol = volumes.first

      item_a = vol["file_a.txt"]
      item_b = vol["file_b.txt"]
      item_c = vol["file_c.txt"]

      done_channel = Channel(Bool).new(30)

      # Spawn 30 concurrent fibers reading and seeking across files
      # Spawn 30 concurrent fibers reading and seeking across files
      10.times do
        spawn do
          item_a.open do |io|
            buf = Bytes.new(500)
            io.seek(5 * 200) # "Alfa " is 5 bytes
            io.read_fully(buf)
            String.new(buf).should start_with("Alfa ")
          end
          done_channel.send(true)
        end

        spawn do
          item_b.open do |io|
            buf = Bytes.new(500)
            io.seek(6 * 300) # "Bravo " is 6 bytes
            io.read_fully(buf)
            String.new(buf).should start_with("Bravo ")
          end
          done_channel.send(true)
        end

        spawn do
          item_c.open do |io|
            buf = Bytes.new(500)
            io.seek(8 * 100) # "Charlie " is 8 bytes
            io.read_fully(buf)
            String.new(buf).should start_with("Charlie ")
          end
          done_channel.send(true)
        end
      end

      # Wait for all 30 fibers to complete
      30.times { done_channel.receive }
    ensure
      BakeliteSpecHelper.cleanup(temp_dir)
    end
  end
end
