/* The C the vault calls: LZ4 1.10.0 and Zstandard 1.5.7 (vendored, vendor/, compiled by lz4_lib.c and zstd_lib.c),
   libsodium (the system's, as Cesia's std/crypto: its security fixes come with the system's updates). Nothing here
   parses a format of its own or writes a primitive: the libraries do.

   Two parts. The core is plain C, with no OCaml value: test/fuzz_vault.c calls it under libFuzzer and the
   sanitizers. The OCaml wrappers below it only convert values: vault/native.ml checks every offset and length before
   the call, nothing here allocates on the OCaml heap (but a context's block), raises, or releases the runtime, so the
   bytes cannot move during a call. A call works on one chunk, 256 KiB at most: under a millisecond. */

#define ZSTD_STATIC_LINKING_ONLY
/* as lz4_lib.c and zstd_lib.c declare them: hidden */
#define LZ4LIB_VISIBILITY __attribute__((visibility("hidden")))
#define ZSTDLIB_VISIBLE __attribute__((visibility("hidden")))
#define ZSTDERRORLIB_VISIBLE __attribute__((visibility("hidden")))
#include "../vendor/lz4-1.10.0/lz4.h"
#include "../vendor/zstd-1.5.7/lib/zstd.h"
#include <sodium.h>

#include <stdint.h>
#include <string.h>


/* ==== the core ==== */

int cph_lz4_bound(int n) { return LZ4_compressBound(n); }

/* the LZ4 block of src[0, n) into dst[0, cap): its length, or 0 when it does not fit */
int cph_lz4_compress(const unsigned char *src, int n, unsigned char *dst, int cap)
{
  return LZ4_compress_default((const char *)src, (char *)dst, n, cap);
}

/* the block src[0, n) decoded into dst[0, raw): 0 when it gives exactly raw bytes, -1 otherwise (the decoder never
   writes past raw nor reads past n: LZ4_decompress_safe) */
int cph_lz4_decompress(const unsigned char *src, int n, unsigned char *dst, int raw)
{
  return LZ4_decompress_safe((const char *)src, (char *)dst, n, raw) == raw ? 0 : -1;
}

size_t cph_zstd_bound(size_t n) { return ZSTD_compressBound(n); }

/* a compression context at a level: frames without a checksum (the vault authenticates every byte) nor a
   dictionary id, with the content size; NULL when out of memory */
ZSTD_CCtx *cph_zstd_cctx(int level)
{
  ZSTD_CCtx *c = ZSTD_createCCtx();
  if (c == NULL) return NULL;
  if (ZSTD_isError(ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, level))
      || ZSTD_isError(ZSTD_CCtx_setParameter(c, ZSTD_c_checksumFlag, 0))
      || ZSTD_isError(ZSTD_CCtx_setParameter(c, ZSTD_c_dictIDFlag, 0))
      || ZSTD_isError(ZSTD_CCtx_setParameter(c, ZSTD_c_contentSizeFlag, 1))) {
    ZSTD_freeCCtx(c);
    return NULL;
  }
  return c;
}

/* a frame of src[0, n) into dst[0, cap): its length, or -1 (it does not fit) */
long cph_zstd_compress(ZSTD_CCtx *c, const unsigned char *src, size_t n, unsigned char *dst, size_t cap)
{
  size_t r = ZSTD_compress2(c, dst, cap, src, n);
  return ZSTD_isError(r) ? -1 : (long)r;
}

/* a decompression context whose window is 1 MiB at most: a frame that asks for more is refused, not given memory */
ZSTD_DCtx *cph_zstd_dctx(void)
{
  ZSTD_DCtx *d = ZSTD_createDCtx();
  if (d == NULL) return NULL;
  if (ZSTD_isError(ZSTD_DCtx_setParameter(d, ZSTD_d_windowLogMax, 20))) {
    ZSTD_freeDCtx(d);
    return NULL;
  }
  return d;
}

/* one frame src[0, n) decoded into dst[0, raw): 0 when it gives exactly raw bytes, -1 otherwise */
int cph_zstd_decompress(ZSTD_DCtx *d, const unsigned char *src, size_t n, unsigned char *dst, size_t raw)
{
  size_t r = ZSTD_decompressDCtx(d, dst, raw, src, n);
  return (!ZSTD_isError(r) && r == raw) ? 0 : -1;
}

int cph_sodium_init(void) { return sodium_init(); }

/* BLAKE2b-256 of src[0, n) keyed by key[0, 32) (RFC 7693, keyed mode) into out[0, 32) */
void cph_hash(const unsigned char *key, const unsigned char *src, size_t n, unsigned char *out)
{
  crypto_generichash(out, 32, src, n, key, 32);
}

/* the subkey number id of key[0, 32) (crypto_kdf: BLAKE2b keyed by the key, the id and the context "cphvault") */
void cph_derive(const unsigned char *key, uint64_t id, unsigned char *out)
{
  crypto_kdf_derive_from_key(out, 32, id, "cphvault", key);
}

/* AEGIS-256 of src[0, n) under key[0, 32), nonce[0, 32), with ad[0, adn) authenticated: n + 32 bytes into dst
   (the ciphertext, then the tag) */
void cph_seal(const unsigned char *key, const unsigned char *nonce, const unsigned char *ad, size_t adn,
              const unsigned char *src, size_t n, unsigned char *dst)
{
  unsigned long long out;
  crypto_aead_aegis256_encrypt(dst, &out, src, n, ad, adn, NULL, nonce, key);
}

/* the plain text of src[0, n) (ciphertext and tag, n >= 32) into dst[0, n - 32): 0 when the tag checks (in constant
   time, by libsodium), -1 otherwise, dst then holding nothing of the plain text */
int cph_open(const unsigned char *key, const unsigned char *nonce, const unsigned char *ad, size_t adn,
             const unsigned char *src, size_t n, unsigned char *dst)
{
  unsigned long long out;
  if (n < crypto_aead_aegis256_ABYTES) return -1;
  return crypto_aead_aegis256_decrypt(dst, &out, NULL, src, n, ad, adn, nonce, key) == 0 ? 0 : -1;
}

void cph_random(unsigned char *buf, size_t n) { randombytes_buf(buf, n); }

/* ==== the OCaml wrappers ==== */

#ifndef CEPHEUS_VAULT_CORE_ONLY

#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#define B(v, off) ((unsigned char *)Bytes_val(v) + Long_val(off))
#define S(v) ((const unsigned char *)String_val(v))

value cph_ml_lz4_bound(value n) { return Val_long(cph_lz4_bound(Int_val(n))); }

value cph_ml_lz4_compress(value src, value off, value len, value dst, value doff, value cap)
{
  return Val_long(cph_lz4_compress(B(src, off), Int_val(len), B(dst, doff), Int_val(cap)));
}
value cph_ml_lz4_compress_byte(value *a, int n) { (void)n; return cph_ml_lz4_compress(a[0], a[1], a[2], a[3], a[4], a[5]); }

value cph_ml_lz4_decompress(value src, value off, value len, value dst, value doff, value raw)
{
  return Val_bool(cph_lz4_decompress(B(src, off), Int_val(len), B(dst, doff), Int_val(raw)) == 0);
}
value cph_ml_lz4_decompress_byte(value *a, int n) { (void)n; return cph_ml_lz4_decompress(a[0], a[1], a[2], a[3], a[4], a[5]); }

value cph_ml_zstd_bound(value n) { return Val_long(cph_zstd_bound((size_t)Long_val(n))); }

#define Cctx_val(v) (*((ZSTD_CCtx **)Data_custom_val(v)))
#define Dctx_val(v) (*((ZSTD_DCtx **)Data_custom_val(v)))

static void cctx_finalize(value v) { ZSTD_freeCCtx(Cctx_val(v)); }
static void dctx_finalize(value v) { ZSTD_freeDCtx(Dctx_val(v)); }

static struct custom_operations cctx_ops = { "cepheus.vault.zstd_cctx", cctx_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default };
static struct custom_operations dctx_ops = { "cepheus.vault.zstd_dctx", dctx_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default };

value cph_ml_zstd_cctx(value level)
{
  ZSTD_CCtx *c = cph_zstd_cctx(Int_val(level));
  if (c == NULL) caml_raise_out_of_memory();
  value v = caml_alloc_custom_mem(&cctx_ops, sizeof(ZSTD_CCtx *), ZSTD_sizeof_CCtx(c) + (1 << 20));
  Cctx_val(v) = c;
  return v;
}

value cph_ml_zstd_dctx(value unit)
{
  (void)unit;
  ZSTD_DCtx *d = cph_zstd_dctx();
  if (d == NULL) caml_raise_out_of_memory();
  value v = caml_alloc_custom_mem(&dctx_ops, sizeof(ZSTD_DCtx *), ZSTD_sizeof_DCtx(d) + (128 << 10));
  Dctx_val(v) = d;
  return v;
}

value cph_ml_zstd_compress(value c, value src, value off, value len, value dst, value doff, value cap)
{
  return Val_long(cph_zstd_compress(Cctx_val(c), B(src, off), (size_t)Long_val(len), B(dst, doff), (size_t)Long_val(cap)));
}
value cph_ml_zstd_compress_byte(value *a, int n) { (void)n; return cph_ml_zstd_compress(a[0], a[1], a[2], a[3], a[4], a[5], a[6]); }

value cph_ml_zstd_decompress(value d, value src, value off, value len, value dst, value doff, value raw)
{
  return Val_bool(cph_zstd_decompress(Dctx_val(d), B(src, off), (size_t)Long_val(len), B(dst, doff), (size_t)Long_val(raw)) == 0);
}
value cph_ml_zstd_decompress_byte(value *a, int n) { (void)n; return cph_ml_zstd_decompress(a[0], a[1], a[2], a[3], a[4], a[5], a[6]); }

value cph_ml_sodium_init(value unit) { (void)unit; return Val_int(cph_sodium_init()); }

value cph_ml_hash(value key, value src, value off, value len, value out)
{
  cph_hash(S(key), B(src, off), (size_t)Long_val(len), (unsigned char *)Bytes_val(out));
  return Val_unit;
}

value cph_ml_derive(value key, value id, value out)
{
  cph_derive(S(key), (uint64_t)Long_val(id), (unsigned char *)Bytes_val(out));
  return Val_unit;
}

value cph_ml_seal(value key, value nonce, value ad, value src, value off, value len, value dst, value doff)
{
  cph_seal(S(key), S(nonce), S(ad), caml_string_length(ad), B(src, off), (size_t)Long_val(len), B(dst, doff));
  return Val_unit;
}
value cph_ml_seal_byte(value *a, int n) { (void)n; return cph_ml_seal(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]); }

value cph_ml_open(value key, value nonce, value ad, value src, value off, value len, value dst, value doff)
{
  return Val_bool(cph_open(S(key), S(nonce), S(ad), caml_string_length(ad), B(src, off), (size_t)Long_val(len), B(dst, doff)) == 0);
}
value cph_ml_open_byte(value *a, int n) { (void)n; return cph_ml_open(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]); }

value cph_ml_random(value buf, value off, value len)
{
  cph_random(B(buf, off), (size_t)Long_val(len));
  return Val_unit;
}

#endif
