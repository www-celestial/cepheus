/* LZ4 1.10.0, vendored verbatim in vendor/lz4-1.10.0 (lz4.c and lz4.h of its lib/, BSD 2-clause): the block format
   only, compiled here as one unit. Its symbols are hidden: the server's binary exports its own symbols (OCaml links it
   with -E for plugins), and a library it loads that links the system's liblz4 must keep calling that one. */
#define LZ4LIB_VISIBILITY __attribute__((visibility("hidden")))
#include "../vendor/lz4-1.10.0/lz4.c"
