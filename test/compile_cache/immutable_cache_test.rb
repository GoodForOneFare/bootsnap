# frozen_string_literal: true

require "test_helper"

class ImmutableCachePrefixTest < Minitest::Test
  include CompileCacheISeqHelper
  include TmpdirHelper

  def setup
    super
    @shared_dir = Dir.mktmpdir("bootsnap-shared")
    @local_dir = Dir.mktmpdir("bootsnap-local")
    @nix_like_dir = Dir.mktmpdir("nix-store")
  end

  def teardown
    FileUtils.remove_entry(@shared_dir)
    FileUtils.remove_entry(@local_dir)
    FileUtils.remove_entry(@nix_like_dir)
    # Reset immutable_cache_prefixes
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = nil
    Bootsnap::CompileCache::YAML.immutable_cache_prefixes = nil
    super
  end

  # --- ISeq immutable cache tests ---

  def test_iseq_cache_dir_for_returns_default_without_shared_prefixes
    Bootsnap::CompileCache::ISeq.cache_dir = @local_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = nil

    dir, immutable = Bootsnap::CompileCache::ISeq.cache_dir_for("/some/random/path.rb")
    assert_equal Bootsnap::CompileCache::ISeq.cache_dir, dir
    refute immutable
  end

  def test_iseq_cache_dir_for_returns_shared_dir_for_matching_prefix
    Bootsnap::CompileCache::ISeq.cache_dir = @local_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    path = File.join(@nix_like_dir, "somegem/lib/foo.rb")
    dir, immutable = Bootsnap::CompileCache::ISeq.cache_dir_for(path)
    assert dir.start_with?(@shared_dir), "Expected #{dir} to start with #{@shared_dir}"
    assert dir.end_with?("iseq"), "Expected #{dir} to end with 'iseq'"
    assert immutable
  end

  def test_iseq_cache_dir_for_returns_default_for_non_matching_prefix
    Bootsnap::CompileCache::ISeq.cache_dir = @local_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    dir, immutable = Bootsnap::CompileCache::ISeq.cache_dir_for("/some/other/path.rb")
    assert_equal Bootsnap::CompileCache::ISeq.cache_dir, dir
    refute immutable
  end

  def test_iseq_longest_prefix_wins
    shorter_prefix = @nix_like_dir
    longer_prefix = File.join(@nix_like_dir, "specific-gem")
    FileUtils.mkdir_p(longer_prefix)

    other_shared = Dir.mktmpdir("bootsnap-other-shared")

    Bootsnap::CompileCache::ISeq.cache_dir = @local_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      shorter_prefix => @shared_dir,
      longer_prefix => other_shared,
    }

    path = File.join(longer_prefix, "lib/foo.rb")
    dir, immutable = Bootsnap::CompileCache::ISeq.cache_dir_for(path)
    assert dir.start_with?(other_shared), "Expected longest prefix match"
    assert immutable
  ensure
    FileUtils.remove_entry(other_shared) if other_shared
  end

  def test_iseq_fetch_uses_immutable_cache_for_matching_path
    Bootsnap::CompileCache::ISeq.cache_dir = @local_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    # Create a real Ruby file under the nix-like dir
    rb_path = File.join(@nix_like_dir, "hello.rb")
    Help.set_file(rb_path, "puts 'hello'", 100)

    # Fetch it — should compile and cache in shared dir
    Bootsnap::CompileCache::ISeq.fetch(rb_path)

    # Verify cache was written to shared dir, not local dir
    shared_iseq_dir = File.join(@shared_dir, "iseq")
    local_iseq_dir = @local_dir.end_with?("/") ? "#{@local_dir}iseq" : "#{@local_dir}-iseq"

    shared_files = Dir.glob(File.join(shared_iseq_dir, "**/*")).select { |f| File.file?(f) }
    local_files = Dir.glob(File.join(local_iseq_dir, "**/*")).select { |f| File.file?(f) }

    assert shared_files.length > 0, "Expected cache files in shared dir #{shared_iseq_dir}"
    assert_equal 0, local_files.length, "Expected no cache files in local dir #{local_iseq_dir}"
  end

  def test_iseq_fetch_uses_local_cache_for_non_matching_path
    Bootsnap::CompileCache::ISeq.cache_dir = @local_dir
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    # Create a Ruby file NOT under the nix-like dir
    other_dir = Dir.mktmpdir("bootsnap-app")
    rb_path = File.join(other_dir, "app.rb")
    Help.set_file(rb_path, "puts 'app'", 100)

    Bootsnap::CompileCache::ISeq.fetch(rb_path)

    # Verify cache was written to local dir, not shared dir
    shared_iseq_dir = File.join(@shared_dir, "iseq")
    local_iseq_dir = Bootsnap::CompileCache::ISeq.cache_dir

    shared_files = Dir.glob(File.join(shared_iseq_dir, "**/*")).select { |f| File.file?(f) }
    local_files = Dir.glob(File.join(local_iseq_dir, "**/*")).select { |f| File.file?(f) }

    assert_equal 0, shared_files.length, "Expected no cache files in shared dir"
    assert local_files.length > 0, "Expected cache files in local dir"
  ensure
    FileUtils.remove_entry(other_dir) if other_dir
  end

  def test_iseq_immutable_cache_hit_across_simulated_worktrees
    # Simulate two worktrees sharing a cache for nix paths.
    # Both use the same shared dir but different local dirs.
    local_dir_1 = Dir.mktmpdir("bootsnap-wt1")
    local_dir_2 = Dir.mktmpdir("bootsnap-wt2")

    rb_path = File.join(@nix_like_dir, "shared_gem.rb")
    Help.set_file(rb_path, "nil", 100)

    # Worktree 1: compile and cache
    Bootsnap::CompileCache::ISeq.cache_dir = local_dir_1
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }
    Bootsnap::CompileCache::ISeq.fetch(rb_path)

    shared_iseq_dir = File.join(@shared_dir, "iseq")
    cached_files = Dir.glob(File.join(shared_iseq_dir, "**/*")).select { |f| File.file?(f) }
    assert cached_files.length > 0, "Worktree 1 should have populated the immutable cache"

    # Worktree 2: should hit the immutable cache (same path, same content, same mtime)
    Bootsnap::CompileCache::ISeq.cache_dir = local_dir_2
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    # Fetch should succeed (returns an ISeq or nil for load_iseq, but fetch itself shouldn't error)
    result = Bootsnap::CompileCache::ISeq.fetch(rb_path)
    # The important thing is no error and the cache in local_dir_2 should be empty
    local_2_files = Dir.glob(File.join(local_dir_2, "**/*")).select { |f| File.file?(f) }
    assert_equal 0, local_2_files.length, "Worktree 2 should not have written to its local dir"
  ensure
    FileUtils.remove_entry(local_dir_1) if local_dir_1
    FileUtils.remove_entry(local_dir_2) if local_dir_2
  end

  # --- instrumentation ---

  def test_immutable_fetch_does_not_report_hit_on_exception
    # Verify that fetch_immutable does not emit :hit when the handler raises
    # during storage_to_output. We populate the cache with a good handler,
    # then read it back with a handler that raises on decode.

    good_handler = Module.new do
      def self.input_to_storage(_, _path)
        "cached data"
      end

      def self.storage_to_output(data, _kwargs)
        data
      end

      def self.input_to_output(_data, _kwargs)
        "direct output"
      end
    end

    bad_handler = Module.new do
      def self.storage_to_output(_data, _kwargs)
        raise RuntimeError, "simulated decode failure"
      end

      def self.input_to_output(_data, _kwargs)
        "fallback output"
      end
    end

    cache_dir = Dir.mktmpdir("bootsnap-immutable-instr")
    rb_path = File.join(@nix_like_dir, "raises.rb")
    Help.set_file(rb_path, "nil", 100)

    # Populate the cache with the good handler
    Bootsnap::CompileCache::Native.fetch(cache_dir, rb_path, good_handler, nil)

    # Now read with bad_handler via fetch_immutable — storage_to_output will raise.
    # fetch_immutable should NOT emit :hit before the exception propagates.
    calls = []
    Bootsnap.instrumentation = ->(event, path) { calls << [event, path] }

    assert_raises(RuntimeError) do
      Bootsnap::CompileCache::Native.fetch_immutable(cache_dir, rb_path, bad_handler, nil)
    end

    hit_events = calls.select { |event, _| event == :hit }
    assert_empty hit_events, "Should not report :hit when storage_to_output raises"
  ensure
    Bootsnap.instrumentation = nil
    FileUtils.remove_entry(cache_dir) if cache_dir
  end

  # --- immutable_cache_prefixes= normalization ---

  def test_immutable_cache_prefixes_adds_trailing_slash
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      "/nix/store" => "/tmp/cache",
    }

    prefixes = Bootsnap::CompileCache::ISeq.immutable_cache_prefixes
    assert_equal "/nix/store/", prefixes.first[0]
  end

  def test_immutable_cache_prefixes_preserves_existing_trailing_slash
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {
      "/nix/store/" => "/tmp/cache",
    }

    prefixes = Bootsnap::CompileCache::ISeq.immutable_cache_prefixes
    assert_equal "/nix/store/", prefixes.first[0]
    refute_equal "/nix/store//", prefixes.first[0]
  end

  def test_immutable_cache_prefixes_nil_when_empty
    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = {}
    assert_nil Bootsnap::CompileCache::ISeq.immutable_cache_prefixes

    Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = nil
    assert_nil Bootsnap::CompileCache::ISeq.immutable_cache_prefixes
  end

  # --- YAML immutable cache tests ---

  def test_yaml_cache_dir_for_returns_shared_dir_for_matching_prefix
    Bootsnap::CompileCache::YAML.cache_dir = @local_dir
    Bootsnap::CompileCache::YAML.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    path = File.join(@nix_like_dir, "config/locales/en.yml")
    dir, immutable = Bootsnap::CompileCache::YAML.cache_dir_for(path)
    assert dir.start_with?(@shared_dir), "Expected #{dir} to start with #{@shared_dir}"
    assert dir.end_with?("yaml"), "Expected #{dir} to end with 'yaml'"
    assert immutable
  end

  def test_yaml_cache_dir_for_returns_default_for_non_matching_prefix
    Bootsnap::CompileCache::YAML.cache_dir = @local_dir
    Bootsnap::CompileCache::YAML.immutable_cache_prefixes = {
      @nix_like_dir => @shared_dir,
    }

    dir, immutable = Bootsnap::CompileCache::YAML.cache_dir_for("/some/other/path.yml")
    assert_equal Bootsnap::CompileCache::YAML.cache_dir, dir
    refute immutable
  end

  def test_build_immutable_packs_is_a_no_op
    assert_equal 0, Bootsnap.build_immutable_packs
  end

  # --- env var parsing ---

  def test_parse_immutable_cache_prefixes_basic
    assert_equal(
      { "/nix/store" => "/tmp/cache" },
      Bootsnap.send(:parse_immutable_cache_prefixes, "/nix/store=/tmp/cache"),
    )
  end

  def test_parse_immutable_cache_prefixes_multiple
    assert_equal(
      { "/nix/store" => "/tmp/nix", "/opt/gems" => "/tmp/gems" },
      Bootsnap.send(:parse_immutable_cache_prefixes, "/nix/store=/tmp/nix;/opt/gems=/tmp/gems"),
    )
  end

  def test_parse_immutable_cache_prefixes_ignores_blanks
    assert_equal(
      { "/nix/store" => "/tmp/cache" },
      Bootsnap.send(:parse_immutable_cache_prefixes, "/nix/store=/tmp/cache;;"),
    )
  end

  def test_parse_immutable_cache_prefixes_returns_nil_for_empty
    assert_nil Bootsnap.send(:parse_immutable_cache_prefixes, "")
    assert_nil Bootsnap.send(:parse_immutable_cache_prefixes, ";;")
  end
end
