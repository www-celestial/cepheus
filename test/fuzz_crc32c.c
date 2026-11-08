/* Fuzzes src/crc32c_stubs.c with libFuzzer, AddressSanitizer and UndefinedBehaviorSanitizer: the processor's CRC of
   [len] bytes at [off] of an exact-size heap copy (a read outside them stops the run), from any 32-bit CRC before,
   against the definition bit by bit, whole and cut in two. Not part of dune's build; run from the repository:
     clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -I "$(ocamlfind ocamlc -where)" \
       test/fuzz_crc32c.c src/crc32c_stubs.c -o fuzz_crc32c && ./fuzz_crc32c -max_len=65536 -max_total_time=300
   The input: 4 bytes of CRC before, 2 of offset, 2 of length, 2 of cut, then the bytes; offset, length and cut are
   brought within the bytes, as crc32c.ml checks before every call. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <caml/mlvalues.h>

value cepheus_crc32c_extend(value crc, value buf, value off, value len);
value cepheus_crc32c_supported(value unit);

static uint32_t by_bits(uint32_t crc, const unsigned char *p, size_t n)
{
  uint32_t c = ~crc;
  while (n-- > 0) {
    c ^= *p++;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0x82F63B78u & (0u - (c & 1u)));
  }
  return ~c;
}

static uint32_t stub(uint32_t crc, const unsigned char *b, size_t off, size_t len)
{
  /* an OCaml bytes value points at its first byte: Bytes_val reads nothing before it */
  return (uint32_t)Long_val(cepheus_crc32c_extend(Val_long(crc), (value)b, Val_long(off), Val_long(len)));
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 10 || !Bool_val(cepheus_crc32c_supported(Val_unit))) return 0;
  uint32_t crc = (uint32_t)data[0] | (uint32_t)data[1] << 8 | (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
  size_t n = size - 10;
  size_t off = ((size_t)data[4] | (size_t)data[5] << 8) % (n + 1);
  size_t len = ((size_t)data[6] | (size_t)data[7] << 8) % (n - off + 1);
  size_t cut = ((size_t)data[8] | (size_t)data[9] << 8) % (len + 1);
  unsigned char *b = malloc(n > 0 ? n : 1);
  if (b == NULL) return 0;
  memcpy(b, data + 10, n);
  uint32_t want = by_bits(crc, b + off, len);
  if (stub(crc, b, off, len) != want) __builtin_trap();
  if (stub(stub(crc, b, off, cut), b, off + cut, len - cut) != want) __builtin_trap();
  free(b);
  return 0;
}
