# frozen_string_literal: true

require "bootsnap/bootsnap"
require "zlib"

module Bootsnap
  module CompileCache
    module ISeq
      class << self
        attr_reader(:cache_dir, :immutable_cache_prefixes)

        def cache_dir=(cache_dir)
          @cache_dir = cache_dir.end_with?("/") ? "#{cache_dir}iseq" : "#{cache_dir}-iseq"
        end

        # Set immutable cache prefixes. Each entry maps a path prefix to a shared
        # cache directory. Files under a matching prefix are treated as
        # **immutable**: bootsnap will skip opening and stat'ing the source
        # file on cache hit, trusting the cache unconditionally.
        #
        # WARNING: Only use this for paths that are truly immutable at the
        # filesystem level (e.g. /nix/store/ which is mounted read-only and
        # content-addressed). If used with mutable paths, stale compiled code
        # will be served indefinitely with no way to detect the change.
        #
        # @param prefixes [Hash{String => String}, nil] e.g. {"/nix/store/" => "/home/user/.cache/bootsnap/nix"}
        def immutable_cache_prefixes=(prefixes)
          @gem_packs = {}
          if prefixes && !prefixes.empty?
            # Sort by prefix length descending so longest match wins
            @immutable_cache_prefixes = prefixes.sort_by { |k, _| -k.length }.map do |prefix, dir|
              prefix = File.expand_path(prefix)
              prefix = "#{prefix}/" unless prefix.end_with?("/")
              dir = File.expand_path(dir)
              cache = dir.end_with?("/") ? "#{dir}iseq" : "#{dir}/iseq"
              [prefix.freeze, cache.freeze]
            end.freeze
          else
            @immutable_cache_prefixes = nil
          end


        end

        # Resolve the cache directory for a given source path.
        # Returns [cache_dir, immutable] where immutable is true if the path
        # matches a immutable cache prefix (indicating the source is immutable).
        def cache_dir_for(path)
          if @immutable_cache_prefixes
            @immutable_cache_prefixes.each do |prefix, dir|
              return [dir, true] if path.start_with?(prefix)
            end
          end
          [@cache_dir, false]
        end

        def supported?
          CompileCache.supported? && defined?(RubyVM)
        end
      end

      has_ruby_bug_18250 = begin # https://bugs.ruby-lang.org/issues/18250
        if defined? RubyVM::InstructionSequence
          RubyVM::InstructionSequence.compile("def foo(*); ->{ super }; end; def foo(**); ->{ super }; end").to_binary
        end
        false
      rescue TypeError
        true
      end

      if has_ruby_bug_18250
        def self.input_to_storage(_, path)
          iseq = begin
            RubyVM::InstructionSequence.compile_file(path)
          rescue SyntaxError
            return UNCOMPILABLE # syntax error
          end

          begin
            iseq.to_binary
          rescue TypeError
            UNCOMPILABLE # ruby bug #18250
          end
        end
      else
        def self.input_to_storage(_, path)
          RubyVM::InstructionSequence.compile_file(path).to_binary
        rescue SyntaxError
          UNCOMPILABLE # syntax error
        end
      end

      def self.storage_to_output(binary, _args)
        iseq = RubyVM::InstructionSequence.load_from_binary(binary)
        binary.clear
        iseq
      rescue RuntimeError => error
        if error.message == "broken binary format"
          $stderr.puts("[Bootsnap::CompileCache] warning: rejecting broken binary")
          nil
        else
          raise
        end
      end

      def self.fetch(path)
        path = path.to_s

        # Fast path for immutable (nix store) paths:
        # Check for per-gem pack first, fall back to individual cache file.
        if @immutable_cache_prefixes&.any? { |prefix, _| path.start_with?(prefix) }
          # Try per-gem pack (mmap'd, binary search, zero per-file syscalls)
          if (pack = gem_pack_for(path))
            result = Bootsnap::CompileCache::Native.fetch_from_immutable_pack(
              pack, path, Bootsnap::CompileCache::ISeq, nil
            )
            return result if result
          end

          # Fallback: individual immutable cache file (skips source stat)
          cache_dir, _ = ISeq.cache_dir_for(path)
          return Bootsnap::CompileCache::Native.fetch_immutable(
            cache_dir, path, Bootsnap::CompileCache::ISeq, nil,
          )
        end

        # Normal mutable path (full source stat + cache validation)
        Bootsnap::CompileCache::Native.fetch(
          @cache_dir, path, Bootsnap::CompileCache::ISeq, nil,
        )
      end

      # Find or lazy-load the per-gem iseq pack for a source path.
      # Pack files are stored in the immutable cache directory (writable),
      # keyed by the gem root's fnv1a hash. Each pack is mmap'd on first
      # access and cached for the process lifetime.
      #
      # Gems that are loaded without a pack are tracked in @gems_needing_packs
      # so that packs can be auto-built after boot completes.
      #
      # @param path [String] absolute source file path
      # @return [ImmutablePack, nil] pack object or nil if no pack exists
      def self.gem_pack_for(path)
        @gem_packs ||= {}

        gem_root = extract_gem_root(path)
        return nil unless gem_root

        unless @gem_packs.key?(gem_root)
          pack_path = gem_pack_path(gem_root)
          if pack_path && Bootsnap::CompileCache::Native.respond_to?(:load_immutable_pack) && File.exist?(pack_path)
            @gem_packs[gem_root] = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
          else
            @gem_packs[gem_root] = nil
            (@gems_needing_packs ||= Set.new) << gem_root
          end
        end

        @gem_packs[gem_root]
      end

      # Compute the pack file path for a gem root. The pack lives in the
      # immutable cache directory (which is writable), not in the gem root
      # (which may be read-only, e.g. /nix/store/).
      # Returns nil if the gem isn't under an immutable prefix.
      def self.gem_pack_path(gem_root)
        cache_dir, immutable = ISeq.cache_dir_for("#{gem_root}/lib/x.rb")
        return nil unless immutable
        require "bootsnap/compile_cache/immutable_pack"
        h = Bootsnap::CompileCache::ImmutablePack.send(:fnv1a_64, gem_root)
        "#{cache_dir}/packs/%016x.pack" % h
      end

      # Auto-build per-gem packs for immutable gems that were loaded without one.
      # Call this after boot completes. Individual cache files (written during
      # first boot) are consolidated into per-gem packs. On next boot, the packs
      # are mmap'd and individual files are never opened.
      #
      # @return [Integer] number of packs built
      def self.build_pending_gem_packs
        return 0 unless @gems_needing_packs&.any?
        return 0 unless @immutable_cache_prefixes

        require "bootsnap/compile_cache/immutable_pack"
        require "fileutils"

        built = 0
        @gems_needing_packs.each do |gem_root|
          cache_dir, immutable = ISeq.cache_dir_for("#{gem_root}/lib/x.rb")
          next unless immutable

          pack_path = gem_pack_path(gem_root)
          next unless pack_path

          FileUtils.mkdir_p(File.dirname(pack_path))

          source_paths = Dir.glob("#{gem_root}/**/*.rb").sort
          next if source_paths.empty?

          count = Bootsnap::CompileCache::ImmutablePack.build(
            source_paths: source_paths,
            cache_dir: cache_dir,
            output_path: pack_path,
          )
          built += 1 if count > 0
        end

        @gems_needing_packs.clear
        built
      end

      # Extract the gem root directory from an absolute source file path.
      # Handles both regular gems and bundler git gems:
      #   /nix/store/HASH/lib/ruby/gems/3.4.0/gems/json-2.19.2/lib/json.rb
      #     → /nix/store/HASH/lib/ruby/gems/3.4.0/gems/json-2.19.2
      #   /nix/store/HASH/lib/ruby/gems/3.4.0/bundler/gems/rails-abc123/lib/rails.rb
      #     → /nix/store/HASH/lib/ruby/gems/3.4.0/bundler/gems/rails-abc123
      GEM_ROOT_RE = %r{(.*?/(?:bundler/)?gems/[^/]+)(?:/.+)}.freeze

      def self.extract_gem_root(path)
        if (m = GEM_ROOT_RE.match(path))
          m[1]
        end
      end

      def self.precompile(path)
        path = path.to_s
        cache_dir, _immutable = ISeq.cache_dir_for(path)
        Bootsnap::CompileCache::Native.precompile(
          cache_dir,
          path,
          Bootsnap::CompileCache::ISeq,
        )
      end

      def self.input_to_output(_data, _kwargs)
        nil # ruby handles this
      end

      module InstructionSequenceMixin
        def load_iseq(path)
          # Having coverage enabled prevents iseq dumping/loading.
          return nil if defined?(Coverage) && Coverage.running?

          Bootsnap::CompileCache::ISeq.fetch(path.to_s)
        rescue RuntimeError => error
          if error.message =~ /unmatched platform/
            puts("unmatched platform for file #{path}")
          end
          raise
        end

        def compile_option=(hash)
          super
          Bootsnap::CompileCache::ISeq.compile_option_updated
        end
      end

      def self.compile_option_updated
        option = RubyVM::InstructionSequence.compile_option
        crc = Zlib.crc32(option.inspect)
        Bootsnap::CompileCache::Native.compile_option_crc32 = crc
      end
      compile_option_updated if supported?

      def self.install!(cache_dir, immutable_cache_prefixes: nil)
        Bootsnap::CompileCache::ISeq.cache_dir = cache_dir
        Bootsnap::CompileCache::ISeq.immutable_cache_prefixes = immutable_cache_prefixes

        return unless supported?

        Bootsnap::CompileCache::ISeq.compile_option_updated

        class << RubyVM::InstructionSequence
          prepend(InstructionSequenceMixin)
        end
      end
    end
  end
end
