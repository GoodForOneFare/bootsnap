# frozen_string_literal: true

# test_helper is loaded by the test runner (see run_pack_tests.rb)
# require "test_helper"
require "bootsnap/compile_cache/immutable_pack"

class ImmutablePackTest < Minitest::Test
  include CompileCacheISeqHelper
  include TmpdirHelper

  def setup
    super
    @shared_dir = Dir.mktmpdir("bootsnap-shared")
    @nix_like_dir = Dir.mktmpdir("nix-store")

    # Create a fake gem structure that extract_gem_root recognizes
    @gem_root = File.join(@nix_like_dir, "lib/ruby/gems/3.4.0/gems/fakegem-1.0.0")
    @gem_lib = File.join(@gem_root, "lib")
    FileUtils.mkdir_p(@gem_lib)

    # Write some .rb files
    Help.set_file(File.join(@gem_lib, "fakegem.rb"), "module FakeGem; VERSION = '1.0.0'; end", 100)
    Help.set_file(File.join(@gem_lib, "fakegem/helper.rb"), "module FakeGem; module Helper; end; end", 100)
    Help.set_file(File.join(@gem_lib, "fakegem/util.rb"), "module FakeGem; module Util; end; end", 100)

    # Configure bootsnap
    Bootsnap::CompileCache::ISeq.cache_dir = @shared_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }
  end

  def teardown
    FileUtils.remove_entry(@shared_dir)
    FileUtils.remove_entry(@nix_like_dir)
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = nil
    super
  end

  # --- Pack roundtrip: build → load → fetch ---

  def test_pack_roundtrip
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort

    # First: compile individual cache files
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    # Build pack
    cache_dir = iseq_cache_dir
    pack_path = pack_path_for(@gem_root)
    FileUtils.mkdir_p(File.dirname(pack_path))

    count = Bootsnap::CompileCache::ImmutablePack.build(
      source_paths: source_paths,
      cache_dir: cache_dir,
      output_path: pack_path,
    )
    assert_equal 3, count
    assert File.exist?(pack_path)

    # Load pack
    pack = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
    refute_nil pack, "Pack should load successfully"

    # Fetch from pack
    source_paths.each do |path|
      result = Bootsnap::CompileCache::Native.fetch_from_immutable_pack(
        pack, path, Bootsnap::CompileCache::ISeq, nil
      )
      refute_nil result, "Expected pack hit for #{path}"
    end
  end

  def test_pack_miss_returns_nil
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    pack_path = pack_path_for(@gem_root)
    FileUtils.mkdir_p(File.dirname(pack_path))

    Bootsnap::CompileCache::ImmutablePack.build(
      source_paths: source_paths,
      cache_dir: iseq_cache_dir,
      output_path: pack_path,
    )

    pack = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
    result = Bootsnap::CompileCache::Native.fetch_from_immutable_pack(
      pack, "/nonexistent/path.rb", Bootsnap::CompileCache::ISeq, nil
    )
    assert_nil result, "Expected nil for path not in pack"
  end

  # --- Stale pack rejection ---

  def test_stale_pack_returns_nil_on_load
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    pack_path = pack_path_for(@gem_root)
    FileUtils.mkdir_p(File.dirname(pack_path))

    Bootsnap::CompileCache::ImmutablePack.build(
      source_paths: source_paths,
      cache_dir: iseq_cache_dir,
      output_path: pack_path,
    )

    # Corrupt the pack header: change ruby_revision field (bytes 16-19)
    data = File.binread(pack_path)
    data.setbyte(16, 0xff)
    data.setbyte(17, 0xff)
    data.setbyte(18, 0xff)
    data.setbyte(19, 0xff)
    File.binwrite(pack_path, data)

    pack = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
    assert_nil pack, "Expected nil for pack with mismatched runtime"
  end

  # --- Stale individual entries excluded from pack build ---

  def test_stale_cache_entries_excluded_from_pack
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    # Corrupt one individual cache file's header (change version field)
    cache_dir = iseq_cache_dir
    corrupt_path = source_paths.first
    cp = cache_file_path(cache_dir, corrupt_path)
    assert File.exist?(cp), "Cache file should exist"
    data = File.binread(cp)
    data.setbyte(0, 0xff)
    data.setbyte(1, 0xff)
    data.setbyte(2, 0xff)
    data.setbyte(3, 0xff)
    File.binwrite(cp, data)

    pack_path = pack_path_for(@gem_root)
    FileUtils.mkdir_p(File.dirname(pack_path))

    count = Bootsnap::CompileCache::ImmutablePack.build(
      source_paths: source_paths,
      cache_dir: cache_dir,
      output_path: pack_path,
    )

    # Only 2 of 3 entries should be included (the corrupted one is skipped)
    assert_equal 2, count
  end

  # --- build_pending_gem_packs end-to-end ---

  def test_build_pending_gem_packs
    # Fetch files — since no pack exists, gems are queued for rebuild
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    # Verify gem was queued
    needs = Bootsnap::CompileCache::ISeq.instance_variable_get(:@gems_needing_packs)
    refute_nil needs
    assert needs.include?(@gem_root), "Expected #{@gem_root} in gems_needing_packs"

    # Build packs
    built = Bootsnap::CompileCache::ISeq.build_pending_gem_packs
    assert_equal 1, built

    # Verify pack was created
    pack_path = Bootsnap::CompileCache::ISeq.gem_pack_path(@gem_root)
    assert File.exist?(pack_path), "Expected pack file at #{pack_path}"

    # Verify pack can be loaded and used
    pack = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
    refute_nil pack

    source_paths.each do |path|
      result = Bootsnap::CompileCache::Native.fetch_from_immutable_pack(
        pack, path, Bootsnap::CompileCache::ISeq, nil
      )
      refute_nil result, "Expected pack hit for #{path}"
    end
  end

  def test_build_pending_gem_packs_clears_queue
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    Bootsnap::CompileCache::ISeq.build_pending_gem_packs

    needs = Bootsnap::CompileCache::ISeq.instance_variable_get(:@gems_needing_packs)
    assert needs.nil? || needs.empty?, "Queue should be cleared after build"
  end

  # --- Readonly mode ---

  def test_build_pending_gem_packs_skipped_in_readonly
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    Bootsnap::CompileCache.instance_variable_set(:@readonly, true)
    begin
      built = Bootsnap::CompileCache::ISeq.build_pending_gem_packs
      assert_equal 0, built
    ensure
      Bootsnap::CompileCache.instance_variable_set(:@readonly, false)
    end
  end

  # --- Invalid pack triggers rebuild ---

  def test_invalid_pack_queues_rebuild
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    # Build a valid pack first
    Bootsnap::CompileCache::ISeq.build_pending_gem_packs

    # Corrupt the pack
    pack_path = Bootsnap::CompileCache::ISeq.gem_pack_path(@gem_root)
    data = File.binread(pack_path)
    data.setbyte(16, 0xff)
    data.setbyte(17, 0xff)
    data.setbyte(18, 0xff)
    data.setbyte(19, 0xff)
    File.binwrite(pack_path, data)

    # Clear cached packs so next fetch re-discovers
    Bootsnap::CompileCache::ISeq.instance_variable_set(:@gem_packs, {})

    # Fetch a file — should detect invalid pack and queue for rebuild
    Bootsnap::CompileCache::ISeq.fetch(source_paths.first)

    needs = Bootsnap::CompileCache::ISeq.instance_variable_get(:@gems_needing_packs)
    assert needs&.include?(@gem_root), "Expected gem to be re-queued after invalid pack"
  end

  # --- extract_gem_root ---

  def test_extract_gem_root_regular_gem
    path = "/nix/store/abc123/lib/ruby/gems/3.4.0/gems/json-2.19.2/lib/json/common.rb"
    assert_equal "/nix/store/abc123/lib/ruby/gems/3.4.0/gems/json-2.19.2",
      Bootsnap::CompileCache::ISeq.extract_gem_root(path)
  end

  def test_extract_gem_root_bundler_gem
    path = "/nix/store/abc123/lib/ruby/gems/3.4.0/bundler/gems/rails-abc123/lib/rails.rb"
    assert_equal "/nix/store/abc123/lib/ruby/gems/3.4.0/bundler/gems/rails-abc123",
      Bootsnap::CompileCache::ISeq.extract_gem_root(path)
  end

  def test_extract_gem_root_non_gem_path
    path = "/Users/gord/myapp/lib/foo.rb"
    assert_nil Bootsnap::CompileCache::ISeq.extract_gem_root(path)
  end

  # --- Atomic write ---

  def test_pack_file_is_valid_after_build
    source_paths = Dir.glob("#{@gem_root}/**/*.rb").sort
    source_paths.each { |p| Bootsnap::CompileCache::ISeq.fetch(p) }

    pack_path = pack_path_for(@gem_root)
    FileUtils.mkdir_p(File.dirname(pack_path))

    Bootsnap::CompileCache::ImmutablePack.build(
      source_paths: source_paths,
      cache_dir: iseq_cache_dir,
      output_path: pack_path,
    )

    # File should start with magic bytes
    magic = File.binread(pack_path, 4)
    assert_equal "BSPC", magic

    # Should be loadable
    pack = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
    refute_nil pack
  end

  private

  def iseq_cache_dir
    dir, _ = Bootsnap::CompileCache::ISeq.cache_dir_for(File.join(@gem_root, "lib/x.rb"))
    dir
  end

  def pack_path_for(gem_root)
    Bootsnap::CompileCache::ISeq.gem_pack_path(gem_root)
  end

  def cache_file_path(cache_dir, source_path)
    h = Bootsnap::CompileCache::ImmutablePack.send(:fnv1a_64, source_path)
    first_byte = (h >> 56) & 0xff
    remainder = h & 0x00ffffffffffffff
    format("%s/%02x/%014x", cache_dir, first_byte, remainder)
  end
end
