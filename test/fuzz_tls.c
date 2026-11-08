/* Fuzzes the core of server/tls_stubs.c (plain C on OpenSSL, no OCaml value) with libFuzzer, AddressSanitizer and
   UndefinedBehaviorSanitizer. Not part of dune's build; run from the repository:
     clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -DCEPHEUS_TLS_CORE_ONLY \
       test/fuzz_tls.c server/tls_stubs.c -lssl -lcrypto -o fuzz_tls && ./fuzz_tls -max_len=16384 -max_total_time=300
   At start it makes a cluster's certificates with cph_tls_make_cert (a CA, a server's for 127.0.0.1, a client's) in
   a fresh directory under the current one, removed at exit, and the contexts that read them. The first byte of an
   input chooses what the rest drives:
     0  a server's connection fed the rest as a client's bytes, in pieces whose sizes the input gives
     1  a client's connection (the CA and the host checked) fed the rest as a server's bytes
     2  a client and a server talking through memory: the input says, step by step, which side takes a handshake
        step, moves a piece of its output to the other (at most one byte of the conversation changed on the way),
        writes plain bytes, or reads them in pieces of a given size. Checked at every read: what a side reads is a
        prefix of what the other wrote (TLS authenticates every record: a changed byte is never read as data). At the
        end, with nothing changed, both handshakes have ended and each side has read everything the other wrote.
     3  a certificate signed by the CA for a common name and a subjectAltName taken from the input (cph_tls_cert)
   A failure stops the run (__builtin_trap) and libFuzzer saves the input. */

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  SSL *ssl;
  BIO *in, *out;
} cph_tls;

SSL_CTX *cph_tls_ctx(int server, const char *ca, const char *cert, const char *key, int verify_peer, char *err,
                     size_t n);
cph_tls *cph_tls_new(SSL_CTX *ctx, int server, const char *host, char *err, size_t n);
void cph_tls_free(cph_tls *c);
int cph_tls_handshake(cph_tls *c, char *err, size_t n);
int cph_tls_feed(cph_tls *c, const unsigned char *p, int len);
int cph_tls_take(cph_tls *c, unsigned char *p, int len);
long cph_tls_pending(cph_tls *c);
int cph_tls_read(cph_tls *c, unsigned char *p, int len, char *err, size_t n);
int cph_tls_write(cph_tls *c, const unsigned char *p, int len, char *err, size_t n);
void cph_tls_peer_name(cph_tls *c, char *name, size_t n);
void cph_tls_close(cph_tls *c);
X509 *cph_tls_cert(EVP_PKEY *k, X509 *issuer, EVP_PKEY *ik, const char *cn, const char *san, int days);
int cph_tls_make_cert(const char *ca_cert, const char *ca_key, const char *cn, const char *san, int days,
                      const char *key_path, const char *cert_path, char *err, size_t n);

#define CHECK(c)                                                                                                  \
  do {                                                                                                            \
    if (!(c)) {                                                                                                   \
      fprintf(stderr, "fuzz_tls: %s (line %d)\n", #c, __LINE__);                                                  \
      __builtin_trap();                                                                                           \
    }                                                                                                             \
  } while (0)

static char dir[64];
static char files[6][128];
static SSL_CTX *server_ctx, *mutual_ctx, *client_ctx, *client_cert_ctx;
static X509 *ca;
static EVP_PKEY *ca_key, *some_key;

static void cleanup(void) {
  for (int i = 0; i < 6; i++) unlink(files[i]);
  rmdir(dir);
}

static void setup(void) {
  char err[512];
  snprintf(dir, sizeof dir, "./fuzz-tls-XXXXXX");
  CHECK(mkdtemp(dir) != NULL);
  const char *names[6] = {"ca.pem", "ca.key", "srv.pem", "srv.key", "cli.pem", "cli.key"};
  for (int i = 0; i < 6; i++) snprintf(files[i], sizeof files[i], "%s/%s", dir, names[i]);
  atexit(cleanup);
  CHECK(cph_tls_make_cert("", "", "fuzz CA", "", 30, files[1], files[0], err, sizeof err) == 0);
  CHECK(cph_tls_make_cert(files[0], files[1], "srv1", "DNS:srv1,IP:127.0.0.1", 30, files[3], files[2], err,
                          sizeof err) == 0);
  CHECK(cph_tls_make_cert(files[0], files[1], "cli", "DNS:cli", 30, files[5], files[4], err, sizeof err) == 0);
  /* made once: a second make on the same files is refused */
  CHECK(cph_tls_make_cert("", "", "again", "", 30, files[1], files[0], err, sizeof err) == -1);
  server_ctx = cph_tls_ctx(1, files[0], files[2], files[3], 0, err, sizeof err);
  mutual_ctx = cph_tls_ctx(1, files[0], files[2], files[3], 1, err, sizeof err);
  client_ctx = cph_tls_ctx(0, files[0], "", "", 1, err, sizeof err);
  client_cert_ctx = cph_tls_ctx(0, files[0], files[4], files[5], 1, err, sizeof err);
  CHECK(server_ctx && mutual_ctx && client_ctx && client_cert_ctx);
  /* a missing file is an error with a reason, not a crash */
  CHECK(cph_tls_ctx(1, "./no-such-ca.pem", "", "", 0, err, sizeof err) == NULL && err[0] != '\0');
  FILE *f = fopen(files[0], "r");
  ca = PEM_read_X509(f, NULL, NULL, NULL);
  fclose(f);
  f = fopen(files[1], "r");
  ca_key = PEM_read_PrivateKey(f, NULL, NULL, NULL);
  fclose(f);
  some_key = EVP_EC_gen("P-256");
  CHECK(ca && ca_key && some_key);
}

/* the input, read as it is used up */
typedef struct {
  const uint8_t *p;
  size_t n;
} in_t;

static int byte(in_t *in) {
  if (in->n == 0) return -1;
  in->n--;
  return *in->p++;
}

static int u16(in_t *in) {
  int a = byte(in), b = byte(in);
  return a < 0 || b < 0 ? -1 : a | b << 8;
}

static unsigned char buf[16384];

/* modes 0 and 1: one side fed the input as its peer's bytes */
static void one_side(in_t *in, int server) {
  char err[512];
  cph_tls *c = cph_tls_new(server ? server_ctx : client_ctx, server, server ? "" : "127.0.0.1", err, sizeof err);
  CHECK(c != NULL);
  int done = 0, failed = 0;
  err[0] = '\0';
  while (in->n > 0 && !failed) {
    int k = byte(in) + 1;
    if ((size_t)k > in->n) k = (int)in->n;
    CHECK(cph_tls_feed(c, in->p, k) == 0);
    in->p += k;
    in->n -= k;
    if (!done) {
      int r = cph_tls_handshake(c, err, sizeof err);
      if (r < 0) failed = 1;
      done = r == 1;
    }
    if (done) {
      int r = cph_tls_read(c, buf, sizeof buf, err, sizeof err);
      CHECK(r >= -2 && r <= (int)sizeof buf);
      if (r == -1) break;
      if (r == -2) failed = 1;
    }
    while (cph_tls_pending(c) > 0) CHECK(cph_tls_take(c, buf, sizeof buf) > 0);
  }
  if (failed) CHECK(err[0] != '\0');
  cph_tls_free(c);
}

/* mode 2: a client and a server through memory */
typedef struct {
  cph_tls *c;
  int done, failed, closed;
  unsigned char *sent; /* what this side wrote */
  size_t nsent;
  size_t nread; /* how much of the other side's bytes this side has read */
} side;

static void hs(side *s) {
  char err[512];
  if (s->done || s->failed) return;
  int r = cph_tls_handshake(s->c, err, sizeof err);
  if (r < 0) {
    CHECK(err[0] != '\0');
    s->failed = 1;
  } else
    s->done = r == 1;
}

/* a piece of [from]'s output to [to]; [flip]: a byte of it changed (at [at], its bits [mask]) */
static size_t moved;

static int move(side *from, side *to, int len, long flip_at, int mask, int *flipped) {
  int k = cph_tls_take(from->c, buf, len);
  CHECK(k >= 0 && k <= len);
  if (k == 0) return 0;
  if (!*flipped && flip_at >= 0 && (size_t)flip_at >= moved && (size_t)flip_at < moved + (size_t)k && mask != 0) {
    buf[flip_at - moved] ^= (unsigned char)mask;
    *flipped = 1;
  }
  moved += k;
  CHECK(cph_tls_feed(to->c, buf, k) == 0);
  return k;
}

static void wr(side *s, int len, uint8_t seed) {
  char err[512];
  if (!s->done || s->failed || s->closed || len == 0) return;
  for (int i = 0; i < len; i++) buf[i] = (unsigned char)(seed + 31 * (s->nsent + i));
  if (cph_tls_write(s->c, buf, len, err, sizeof err) != 0) {
    s->failed = 1;
    return;
  }
  s->sent = realloc(s->sent, s->nsent + len);
  CHECK(s->sent != NULL);
  memcpy(s->sent + s->nsent, buf, len);
  s->nsent += len;
}

static void rd(side *s, side *peer, int len) {
  char err[512];
  if (s->failed || len == 0) return;
  int r = cph_tls_read(s->c, buf, len, err, sizeof err);
  CHECK(r >= -2 && r <= len);
  if (r > 0) {
    /* never a byte the peer did not write, never out of order */
    CHECK(s->nread + r <= peer->nsent);
    CHECK(memcmp(buf, peer->sent + s->nread, r) == 0);
    s->nread += r;
  } else if (r == -2)
    s->failed = 1;
}

static void pair(in_t *in) {
  char err[512];
  int mode = byte(in);
  if (mode < 0) return;
  side cl = {0}, sv = {0};
  cl.c = cph_tls_new((mode & 1) ? client_cert_ctx : client_ctx, 0, (mode & 2) ? "srv1" : "127.0.0.1", err, sizeof err);
  sv.c = cph_tls_new((mode & 1) ? mutual_ctx : server_ctx, 1, "", err, sizeof err);
  CHECK(cl.c && sv.c);
  long flip_at = -1;
  int mask = 0, flipped = 0;
  if (mode & 4) {
    flip_at = u16(in);
    mask = byte(in);
  }
  moved = 0;
  while (in->n > 0) {
    int op = byte(in), len = u16(in);
    if (op < 0 || len < 0) break;
    len = len % (int)sizeof buf;
    switch (op % 8) {
      case 0: hs(&cl); break;
      case 1: hs(&sv); break;
      case 2: move(&cl, &sv, len + 1, flip_at, mask, &flipped); break;
      case 3: move(&sv, &cl, len + 1, flip_at, mask, &flipped); break;
      case 4: wr(&cl, len, (uint8_t)op); break;
      case 5: wr(&sv, len, (uint8_t)op); break;
      case 6: rd(&sv, &cl, len + 1); break;
      case 7: rd(&cl, &sv, len + 1); break;
    }
  }
  /* to the end: every byte moved, every handshake step and read taken, until nothing moves (each round moves or reads
     something, or ends the loop: at most one round a record) */
  for (;;) {
    hs(&cl);
    hs(&sv);
    int m = 0;
    while (move(&cl, &sv, sizeof buf, flip_at, mask, &flipped) > 0) m = 1;
    while (move(&sv, &cl, sizeof buf, flip_at, mask, &flipped) > 0) m = 1;
    size_t a = sv.nread, b = cl.nread;
    if (sv.done) rd(&sv, &cl, sizeof buf);
    if (cl.done) rd(&cl, &sv, sizeof buf);
    if (!m && a == sv.nread && b == cl.nread) break;
  }
  if (!flipped) {
    CHECK(cl.done && sv.done && !cl.failed && !sv.failed);
    CHECK(sv.nread == cl.nsent && cl.nread == sv.nsent);
    char name[256];
    cph_tls_peer_name(cl.c, name, sizeof name);
    CHECK(strcmp(name, "srv1") == 0);
    cph_tls_peer_name(sv.c, name, sizeof name);
    CHECK(strcmp(name, (mode & 1) ? "cli" : "") == 0);
    /* a close_notify ends the other side's stream */
    cph_tls_close(cl.c);
    while (move(&cl, &sv, sizeof buf, -1, 0, &flipped) > 0) {}
    CHECK(cph_tls_read(sv.c, buf, sizeof buf, err, sizeof err) == -1);
  }
  free(cl.sent);
  free(sv.sent);
  cph_tls_free(cl.c);
  cph_tls_free(sv.c);
}

/* mode 3: a certificate for names from the input */
static void cert(in_t *in) {
  int days = byte(in);
  if (days < 0) return;
  char cn[256], san[1024];
  size_t a = in->n < 255 ? in->n : 255;
  size_t cut = a == 0 ? 0 : (size_t)(in->p[0]) % (a + 1);
  memcpy(cn, in->p, cut);
  cn[cut] = '\0';
  size_t b = in->n - cut < sizeof san - 1 ? in->n - cut : sizeof san - 1;
  memcpy(san, in->p + cut, b);
  san[b] = '\0';
  X509 *c = cph_tls_cert(some_key, ca, ca_key, cn, san, days + 1);
  if (c != NULL) {
    EVP_PKEY *pk = X509_get0_pubkey(ca);
    CHECK(X509_verify(c, pk) == 1);
    X509_free(c);
  }
  ERR_clear_error();
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static int ready = 0;
  if (!ready) {
    setup();
    ready = 1;
  }
  in_t in = {data, size};
  int m = byte(&in);
  if (m < 0) return 0;
  switch (m % 4) {
    case 0: one_side(&in, 1); break;
    case 1: one_side(&in, 0); break;
    case 2: pair(&in); break;
    case 3: cert(&in); break;
  }
  ERR_clear_error();
  return 0;
}
