require "./bakelite/version"
require "./bakelite/types"
require "./bakelite/mime"
require "./bakelite/file_io"
require "./bakelite/item"
require "./bakelite/volume"
require "./bakelite/container/format"
require "./bakelite/container/reader"
require "./bakelite/container/writer"
require "./bakelite/fs"
require "./bakelite/chunker"
require "./bakelite/transform/builtins"
require "./bakelite/transform/cache"
require "./bakelite/transform/runner"
require "./bakelite/dsl"

module Bakelite
  include Bakelite::FS
  include Bakelite::DSL

  # Top-level global filesystem registry
  def self.fs : Bakelite::FS::Registry
    Bakelite::FS::Registry.new
  end
end

{% if !flag?(:release) && read_file?("#{__DIR__}/bakelite/docs.cr") %}
  require "./bakelite/docs"
{% end %}
