# frozen_string_literal: true

require "tempfile"

module Bootsnap
  module CompileCache
    # Builds and manages packed immutable cache files.
    #
    # A pack file concatenates all cache entries into a single file with a
    # sorted index, replacing thousands of individual cache files with one
    # mmap'd lookup. This eliminates ~40k syscalls (open/read/close per file)
    # on every boot, replacing them with a single mmap + binary search.
    #
    # File format (v2):
    #   Header (32 bytes):
    #     magic              [4]  "BSPC"
    #     format_version     [4]  uint32 = 2
    #     ruby_platform      [4]  uint32 (FNV-1a of RUBY_PLATFORM)
    #     compile_option     [4]  uint32 (CRC32 of compile_option.inspect)
    #     ruby_revision      [4]  uint32 (FNV-1a of RUBY_REVISION)
    #     entry_count        [4]  uint32
    #     cache_version      [4]  uint32 (bootsnap cache schema version)
    #     reserved           [4]  zero padding
    #
    #   Index (entry_count * 24 bytes, sorted by path_hash):
    #     path_hash       [8]  uint64 FNV-1a of source path
    #     data_offset     [8]  uint64 byte offset from start of file
    #     data_size       [8]  uint64
    #
    #   Data: concatenated raw cache blobs
    module ImmutablePack
      MAGIC = "BSPC"
      FORMAT_VERSION = 2
      HEADER_SIZE = 32
      INDEX_ENTRY_SIZE = 24
      CACHE_KEY_SIZE = 64

      # Cache key layout (first 64 bytes of each individual cache file):
      #   [0..3]   version        uint32
      #   [4..7]   ruby_platform  uint32
      #   [8..11]  compile_option uint32
      #   [12..15] ruby_revision  uint32
      #   [16..23] size           uint64
      #   [24..31] mtime          uint64
      #   [32..39] data_size      uint64
      #   [40..47] digest         uint64
      #   [48]     digest_set     uint8
      #   [49..63] padding
      KEY_VERSION_OFFSET = 0
      KEY_PLATFORM_OFFSET = 4
      KEY_COMPILE_OPT_OFFSET = 8
      KEY_REVISION_OFFSET = 12
      KEY_DATA_SIZE_OFFSET = 32

      class << self
        # Build a pack file from precompiled individual cache files.
        # Validates each cache entry's header before including it.
        # Writes atomically via temp file + rename.
        #
        # @param source_paths [Array<String>] paths that were precompiled
        # @param cache_dir [String] the iseq or yaml cache directory containing individual files
        # @param output_path [String] where to write the pack file
        # @return [Integer] number of entries in the pack
        def build(source_paths:, cache_dir:, output_path:)
          current_ver = bootsnap_cache_version
          current_plat = ruby_platform_hash
          current_opt = ruby_compile_option_crc32
          current_rev = ruby_revision_hash

          entries = []

          source_paths.each do |path|
            cp = cache_file_path(cache_dir, path)
            next unless File.exist?(cp)

            raw = File.binread(cp)
            next if raw.size <= CACHE_KEY_SIZE

            # Validate cache entry header (fix #3: don't bless stale entries)
            key_version = raw.byteslice(KEY_VERSION_OFFSET, 4).unpack1("V")
            key_platform = raw.byteslice(KEY_PLATFORM_OFFSET, 4).unpack1("V")
            key_compile = raw.byteslice(KEY_COMPILE_OPT_OFFSET, 4).unpack1("V")
            key_revision = raw.byteslice(KEY_REVISION_OFFSET, 4).unpack1("V")

            next unless key_version == current_ver &&
                        key_platform == current_plat &&
                        key_compile == current_opt &&
                        key_revision == current_rev

            data_size = raw.byteslice(KEY_DATA_SIZE_OFFSET, 8).unpack1("Q<")
            data = raw.byteslice(CACHE_KEY_SIZE, data_size)
            next unless data && data.bytesize == data_size

            entries << [fnv1a_64(path), data]
          end

          # Sort by path_hash for binary search
          entries.sort_by!(&:first)

          # Atomic write: temp file + rename (fix #5)
          dir = File.dirname(output_path)
          tmp = Tempfile.new("bootsnap-pack-", dir)
          begin
            tmp.binmode

            # Header (now includes cache_version, fix #2)
            tmp.write([
              MAGIC,
              FORMAT_VERSION,
              current_plat,
              current_opt,
              current_rev,
              entries.size,
              current_ver,  # bootsnap cache schema version
              0,            # reserved
            ].pack("a4V7"))

            # Index — compute data offsets
            data_start = HEADER_SIZE + entries.size * INDEX_ENTRY_SIZE
            offset = data_start
            entries.each do |path_hash, data|
              tmp.write([path_hash, offset, data.bytesize].pack("Q<Q<Q<"))
              offset += data.bytesize
            end

            # Data
            entries.each do |_, data|
              tmp.write(data)
            end

            tmp.fsync
            tmp.close
            File.rename(tmp.path, output_path)
          rescue
            tmp.close
            tmp.unlink rescue nil
            raise
          end

          entries.size
        end

        private

        # FNV-1a 64-bit — must match the C implementation exactly
        def fnv1a_64(str)
          h = 0xcbf29ce484222325
          str.each_byte do |byte|
            h ^= byte
            h = (h + (h << 1) + (h << 4) + (h << 5) + (h << 7) + (h << 8) + (h << 40)) & 0xFFFFFFFFFFFFFFFF
          end
          h
        end

        # Compute the cache file path for a source path (mirrors bs_cache_path in C)
        def cache_file_path(cache_dir, source_path)
          h = fnv1a_64(source_path)
          first_byte = (h >> 56) & 0xff
          remainder = h & 0x00ffffffffffffff
          format("%s/%02x/%014x", cache_dir, first_byte, remainder)
        end

        def ruby_platform_hash
          fnv1a_64_to_u32(RUBY_PLATFORM)
        end

        def ruby_compile_option_crc32
          require "zlib"
          Zlib.crc32(RubyVM::InstructionSequence.compile_option.inspect)
        end

        def ruby_revision_hash
          fnv1a_64_to_u32(RUBY_REVISION)
        end

        # The C code stores platform/revision as uint32 from the upper 32 bits of FNV-1a
        def fnv1a_64_to_u32(str)
          h = fnv1a_64(str)
          (h >> 32) & 0xFFFFFFFF
        end

        # Bootsnap's cache schema version (must match current_version in bootsnap.c)
        def bootsnap_cache_version
          # Read from the C extension if available, otherwise use a sensible default
          if Bootsnap::CompileCache::Native.respond_to?(:cache_version)
            Bootsnap::CompileCache::Native.cache_version
          else
            6 # current_version as of bootsnap 1.23
          end
        end
      end
    end
  end
end
