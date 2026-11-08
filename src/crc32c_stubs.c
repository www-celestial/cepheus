/* CRC-32C by the processor's own instruction: crc32 of SSE4.2 on x86-64 (Intel 64 and IA-32 Architectures Software
   Developer's Manual, vol. 2A, "CRC32"), crc32cx and crc32cb of ARMv8 on arm64 (Arm ACLE, __crc32cd and __crc32cb).
   One dependent chain of 8-byte steps. Called by crc32c.ml only, which checks the bounds first; nothing here
   allocates, raises or releases the runtime, so the bytes cannot move during the call. Each function that runs the
   instruction is compiled for it alone (a target attribute): the rest of the file, and the check of the processor,
   run on any CPU of the architecture, so a CPU without the instruction gets a message, not an illegal instruction. */

#include <stdint.h>
#include <string.h>
#include <caml/mlvalues.h>

#if defined(__x86_64__)
#include <nmmintrin.h>
#define CRC_TARGET __attribute__((target("sse4.2")))
#define CRC_STEP8(c, w) ((uint32_t)_mm_crc32_u64((c), (w)))
#define CRC_STEP1(c, b) _mm_crc32_u8((c), (b))
static int crc_supported(void) { return __builtin_cpu_supports("sse4.2"); }
#elif defined(__aarch64__)
#include <arm_acle.h>
#define CRC_TARGET __attribute__((target("+crc")))
#define CRC_STEP8(c, w) __crc32cd((c), (w))
#define CRC_STEP1(c, b) __crc32cb((c), (b))
#if defined(__linux__)
#include <sys/auxv.h>
#ifndef HWCAP_CRC32
#define HWCAP_CRC32 (1 << 7) /* the Linux kernel's arm64 ABI, arch/arm64/include/uapi/asm/hwcap.h */
#endif
static int crc_supported(void) { return (getauxval(AT_HWCAP) & HWCAP_CRC32) != 0; }
#elif defined(__APPLE__)
static int crc_supported(void) { return 1; } /* every arm64 Mac (M1 and later, ARMv8.4 or newer) has them */
#else
#error "Cepheus: the check of the CRC32 instructions is written for Linux and macOS on arm64"
#endif
#else
#error "Cepheus needs a CRC-32C instruction: x86-64 (SSE4.2) or arm64 (CRC32)"
#endif

CRC_TARGET static uint32_t crc_run(uint32_t c, const unsigned char *p, size_t n)
{
  while (n >= 8) {
    uint64_t w;
    memcpy(&w, p, 8); /* any alignment; one load */
    c = CRC_STEP8(c, w);
    p += 8;
    n -= 8;
  }
  while (n > 0) {
    c = CRC_STEP1(c, *p);
    p++;
    n--;
  }
  return c;
}

/* [crc] the CRC of the bytes before, [len] bytes of [buf] from [off]: the CRC of both, as an OCaml int */
value cepheus_crc32c_extend(value crc, value buf, value off, value len)
{
  uint32_t c = (uint32_t)Long_val(crc) ^ 0xFFFFFFFFu;
  c = crc_run(c, (const unsigned char *)Bytes_val(buf) + Long_val(off), (size_t)Long_val(len));
  return Val_long(c ^ 0xFFFFFFFFu);
}

value cepheus_crc32c_supported(value unit)
{
  (void)unit;
  return Val_bool(crc_supported());
}
