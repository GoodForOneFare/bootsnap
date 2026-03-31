# frozen_string_literal: true

module Bootsnap
  module CompileCache
    # Builds and manages packed immutable cache files.
    #
    # A pack file concatenates all cache entries into a single file with a
    # sorted index, replacing thousands of individual cache files with one
    # mmap'd lookup. This eliminates ~40k syscalls (open/read/close per file)
    # on every boot, replacing them with a single mmap + binary search.
    #
    # File format:
    #   Header (32 bytes):
    #     magic           [4]  "BSPC"
    #     format_version  [4]  uint32 = 1
    #     ruby_platform   [4]  uint32 (FNV-1a of RUBY_PLATFORM)
    #     compile_option  [4]  uint32 (CRC32 of compile_option.inspect)
    #     ruby_revision   [4]  uint32 (FNV-1a of RUBY_REVISION)
    #     entry_count     [4]  uint32
    #     reserved        [8]  zero padding
    #
    #   Index (entry_count * 24 bytes, sorted by path_hash):
    #     path_hash       [8]  uint64 FNV-1a of source path
    #     data_offset     [8]  uint64 byte offset from start of file
    #     data_size       [8]  uint64
    #
    #   Data: concatenated raw cache blobs
    module ImmutablePack
      MAGIC = "BSPC"
      FORMAT_VERSION = 1
      HEADER_SIZE = 32
      INDEX_ENTRY_SIZE = 24
      CACHE_KEY_SIZE = 64

      class << self
        # Build a pack file from precompiled individual cache files.
        #
        # @param source_paths [Array<String>] paths that were precompiled
        # @param cache_dir [String] the iseq or yaml cache directory containing individual files
        # @param output_path [String] where to write the pack file
        def build(source_paths:, cache_dir:, output_path:)
          entries = []

          source_paths.each do |path|
            cp = cache_file_path(cache_dir, path)
            next unless File.exist?(cp)

            raw = File.binread(cp)
            next if raw.size <= CACHE_KEY_SIZE

            # data_size is at byte offset 32 in the 64-byte key
            data_size = raw.byteslice(32, 8).unpack1("Q<")
            data = raw.byteslice(CACHE_KEY_SIZE, data_size)
            next unless data && data.bytesize == data_size

            entries << [fnv1a_64(path), data]
          end

          # Sort by path_hash for binary search
          entries.sort_by!(&:first)

          File.open(output_path, "wb") do |f|
            # Header
            f.write([
              MAGIC,
              FORMAT_VERSION,
              ruby_platform_hash,
              ruby_compile_option_crc32,
              ruby_revision_hash,
              entries.size,
              0, 0, # reserved
            ].pack("a4V6V"))

            # Index — compute data offsets
            data_start = HEADER_SIZE + entries.size * INDEX_ENTRY_SIZE
            offset = data_start
            entries.each do |path_hash, data|
              f.write([path_hash, offset, data.bytesize].pack("Q<Q<Q<"))
              offset += data.bytesize
            end

            # Data
            entries.each do |_, data|
              f.write(data)
            end
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
      end
    end
  end
end
