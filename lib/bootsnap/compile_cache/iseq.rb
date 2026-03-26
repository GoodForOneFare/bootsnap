# frozen_string_literal: true

require "bootsnap/bootsnap"
require "zlib"

module Bootsnap
  module CompileCache
    module ISeq
      class << self
        attr_reader(:cache_dir, :immutable_cache_prefixes, :immutable_pack)

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
          @immutable_pack = nil
          if prefixes && !prefixes.empty?
            # Sort by prefix length descending so longest match wins
            @immutable_cache_prefixes = prefixes.sort_by { |k, _| -k.length }.map do |prefix, dir|
              prefix = File.expand_path(prefix)
              prefix = "#{prefix}/" unless prefix.end_with?("/")
              dir = File.expand_path(dir)
              cache = dir.end_with?("/") ? "#{dir}iseq" : "#{dir}/iseq"
              [prefix.freeze, cache.freeze]
            end.freeze

            # Auto-detect pack files: look for iseq.pack alongside the cache dir
            if Bootsnap::CompileCache::Native.respond_to?(:load_immutable_pack)
              @immutable_cache_prefixes.each do |_prefix, cache_dir|
                pack_path = "#{cache_dir}.pack"
                if File.exist?(pack_path)
                  @immutable_pack = Bootsnap::CompileCache::Native.load_immutable_pack(pack_path)
                  break if @immutable_pack
                end
              end
            end
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

        # Fastest path: mmap'd pack file (single binary search, no syscalls).
        # Only checked for paths under an immutable prefix — the pack contains
        # no mutable entries so non-matching paths skip straight to file lookup.
        if @immutable_pack
          if @immutable_cache_prefixes&.any? { |prefix, _| path.start_with?(prefix) }
            result = Bootsnap::CompileCache::Native.fetch_from_immutable_pack(
              @immutable_pack, path, Bootsnap::CompileCache::ISeq, nil
            )
            return result if result
          end
        end

        # Fast path: individual immutable cache file (skips stat of source)
        cache_dir, immutable = ISeq.cache_dir_for(path)
        if immutable
          Bootsnap::CompileCache::Native.fetch_immutable(
            cache_dir,
            path,
            Bootsnap::CompileCache::ISeq,
            nil,
          )
        else
          Bootsnap::CompileCache::Native.fetch(
            cache_dir,
            path,
            Bootsnap::CompileCache::ISeq,
            nil,
          )
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
