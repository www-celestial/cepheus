/* Zstandard 1.5.7, vendored verbatim in vendor/zstd-1.5.7 (lib/common, lib/compress, lib/decompress and the public
   headers, BSD license): compiled here as one unit, as its own build/single_file_libs/zstd-in.c does, without
   multithreading, the legacy formats, the dictionary builder, tracing, or the assembly of the Huffman decoder. Its
   symbols are hidden: the system's libcrypto links the system's libzstd, and the server's binary exports its own
   symbols (OCaml links it with -E for plugins), so an exported copy here would take that library's calls. */
#define ZSTDLIB_VISIBLE __attribute__((visibility("hidden")))
#define ZSTDERRORLIB_VISIBLE __attribute__((visibility("hidden")))
#define DEBUGLEVEL 0
#define MEM_MODULE
#undef XXH_NAMESPACE
#define XXH_NAMESPACE ZSTD_
#undef XXH_PRIVATE_API
#define XXH_PRIVATE_API
#undef XXH_INLINE_ALL
#define XXH_INLINE_ALL
#define ZSTD_LEGACY_SUPPORT 0
#define ZSTD_TRACE 0
#define ZSTD_DISABLE_ASM 1
#define ZSTD_DEPS_NEED_MALLOC
#define ZSTD_DEPS_NEED_MATH64
#include "../vendor/zstd-1.5.7/lib/common/zstd_deps.h"

#include "../vendor/zstd-1.5.7/lib/common/debug.c"
#include "../vendor/zstd-1.5.7/lib/common/entropy_common.c"
#include "../vendor/zstd-1.5.7/lib/common/error_private.c"
#include "../vendor/zstd-1.5.7/lib/common/fse_decompress.c"
#include "../vendor/zstd-1.5.7/lib/common/threading.c"
#include "../vendor/zstd-1.5.7/lib/common/pool.c"
#include "../vendor/zstd-1.5.7/lib/common/zstd_common.c"

#include "../vendor/zstd-1.5.7/lib/compress/fse_compress.c"
#include "../vendor/zstd-1.5.7/lib/compress/hist.c"
#include "../vendor/zstd-1.5.7/lib/compress/huf_compress.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_compress_literals.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_compress_sequences.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_compress_superblock.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_preSplit.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_compress.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_double_fast.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_fast.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_lazy.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_ldm.c"
#include "../vendor/zstd-1.5.7/lib/compress/zstd_opt.c"

#include "../vendor/zstd-1.5.7/lib/decompress/huf_decompress.c"
#include "../vendor/zstd-1.5.7/lib/decompress/zstd_ddict.c"
#include "../vendor/zstd-1.5.7/lib/decompress/zstd_decompress.c"
#include "../vendor/zstd-1.5.7/lib/decompress/zstd_decompress_block.c"
