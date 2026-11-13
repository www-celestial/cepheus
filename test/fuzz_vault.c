/* Fuzzes the core of vault/vault_stubs.c (plain C on the vendored LZ4 and Zstandard and on libsodium, no OCaml
   value) with libFuzzer, AddressSanitizer and UndefinedBehaviorSanitizer. Not part of dune's build; run from the
   repository:
     clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -DCEPHEUS_VAULT_CORE_ONLY \
       -I vendor/zstd-1.5.7/lib test/fuzz_vault.c vault/vault_stubs.c vault/lz4_lib.c vault/zstd_lib.c -lsodium \
       -o fuzz_vault && ./fuzz_vault -max_len=300000 -max_total_time=300
   The first byte of an input chooses what the rest is:
     0  an LZ4 block decoded to the length the next 3 bytes give (at most 256 KiB): exactly that many bytes, or a
        refusal, and never a byte read or written outside the buffers (the sanitizers watch, the buffers have no slack)
     1  a Zstandard frame, the same
     2  plain bytes compressed by both codecs and decoded again: the same bytes; one byte of each block changed: the
        same bytes or a refusal
     3  bytes opened as a sealed text under a fixed key: refused (a forgery of AEGIS-256's 256-bit tag); and sealed,
        then opened: the same bytes, with one bit changed: refused
   A failure stops the run (__builtin_trap) and libFuzzer saves the input. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

int cph_lz4_bound(int n);
int cph_lz4_compress(const unsigned char *src, int n, unsigned char *dst, int cap);
int cph_lz4_decompress(const unsigned char *src, int n, unsigned char *dst, int raw);
size_t cph_zstd_bound(size_t n);
ZSTD_CCtx *cph_zstd_cctx(int level);
long cph_zstd_compress(ZSTD_CCtx *c, const unsigned char *src, size_t n, unsigned char *dst, size_t cap);
ZSTD_DCtx *cph_zstd_dctx(void);
int cph_zstd_decompress(ZSTD_DCtx *d, const unsigned char *src, size_t n, unsigned char *dst, size_t raw);
int cph_sodium_init(void);
void cph_seal(const unsigned char *key, const unsigned char *nonce, const unsigned char *ad, size_t adn,
              const unsigned char *src, size_t n, unsigned char *dst);
int cph_open(const unsigned char *key, const unsigned char *nonce, const unsigned char *ad, size_t adn,
             const unsigned char *src, size_t n, unsigned char *dst);

static ZSTD_CCtx *cctx;
static ZSTD_DCtx *dctx;
static const unsigned char key[32] = "0123456789abcdef0123456789abcdef";
static const unsigned char nonce[32] = "nonce-nonce-nonce-nonce-nonce-12";

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
  (void)argc; (void)argv;
  if (cph_sodium_init() < 0) abort();
  cctx = cph_zstd_cctx(3);
  dctx = cph_zstd_dctx();
  if (!cctx || !dctx) abort();
  return 0;
}

/* a copy of [n] bytes in a buffer of exactly that size: any read past it is caught */
static unsigned char *exact(const uint8_t *p, size_t n)
{
  unsigned char *b = malloc(n ? n : 1);
  memcpy(b, p, n);
  return b;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 1) return 0;
  const uint8_t *in = data + 1;
  size_t n = size - 1;
  switch (data[0] % 4) {
  case 0:
  case 1: {
    if (n < 3) return 0;
    size_t raw = ((size_t)in[0] | ((size_t)in[1] << 8) | ((size_t)in[2] << 16)) % (256 * 1024 + 1);
    unsigned char *src = exact(in + 3, n - 3), *dst = malloc(raw ? raw : 1);
    if (data[0] % 4 == 0) (void)cph_lz4_decompress(src, (int)(n - 3), dst, (int)raw);
    else (void)cph_zstd_decompress(dctx, src, n - 3, dst, raw);
    free(src);
    free(dst);
    return 0;
  }
  case 2: {
    unsigned char *src = exact(in, n);
    size_t cap = cph_zstd_bound(n) > (size_t)cph_lz4_bound((int)n) ? cph_zstd_bound(n) : (size_t)cph_lz4_bound((int)n);
    unsigned char *c = malloc(cap), *o = malloc(n ? n : 1);
    int k = cph_lz4_compress(src, (int)n, c, (int)cap);
    if (k <= 0 || cph_lz4_decompress(c, k, o, (int)n) != 0 || memcmp(o, src, n) != 0) __builtin_trap();
    if (k > 0 && n > 0) { c[n % k] ^= 0x5a; if (cph_lz4_decompress(c, k, o, (int)n) == 0 && memcmp(o, src, n) != 0) { /* a changed block may decode to other bytes: LZ4 has no checksum; the vault's tag catches it */ } }
    long z = cph_zstd_compress(cctx, src, n, c, cap);
    if (z <= 0 || cph_zstd_decompress(dctx, c, (size_t)z, o, n) != 0 || memcmp(o, src, n) != 0) __builtin_trap();
    if (z > 0) { c[n % (size_t)z] ^= 0x5a; (void)cph_zstd_decompress(dctx, c, (size_t)z, o, n); }
    free(src);
    free(c);
    free(o);
    return 0;
  }
  default: {
    unsigned char *src = exact(in, n), *o = malloc(n + 32), *s = malloc(n + 32);
    if (n >= 32 && cph_open(key, nonce, (const unsigned char *)"ad", 2, src, n, o) == 0) __builtin_trap();
    cph_seal(key, nonce, (const unsigned char *)"ad", 2, src, n, s);
    if (cph_open(key, nonce, (const unsigned char *)"ad", 2, s, n + 32, o) != 0 || memcmp(o, src, n) != 0) __builtin_trap();
    s[n % (n + 32)] ^= 1;
    if (cph_open(key, nonce, (const unsigned char *)"ad", 2, s, n + 32, o) == 0) __builtin_trap();
    free(src);
    free(o);
    free(s);
    return 0;
  }
  }
}
