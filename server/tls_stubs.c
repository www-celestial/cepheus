/* TLS 1.3 by OpenSSL 3, the system's libssl (security fixes come with the system's updates): contexts, a handshake
   on memory buffers, reads and writes, the peer's verified name, and the certificates of a cluster (an ECDSA P-256
   CA, and certificates it signs). Nothing here parses a protocol: OpenSSL does.

   Two parts. The core is plain C on OpenSSL, with no OCaml value: test/fuzz_tls.c calls it directly under
   libFuzzer and the sanitizers. The OCaml wrappers below it only convert values and raise errors; every call that
   waits or computes (handshakes, key generation) releases the OCaml runtime lock, and bytes cross through the
   caller's buffers within bounds that server/tls.ml checks. The interface is server/tls.ml. */

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ==== the core ==== */

/* the first error of OpenSSL's queue after [what], into err[0 .. n-1]; the queue is cleared */
static void cph_err(char *err, size_t n, const char *what) {
  unsigned long e = ERR_get_error();
  if (e != 0) {
    char reason[256];
    ERR_error_string_n(e, reason, sizeof reason);
    snprintf(err, n, "%s: %s", what, reason);
  } else
    snprintf(err, n, "%s", what);
  ERR_clear_error();
}

/* [server]: 1 for a server's context. [ca]: the cluster's CA, whose certificates are trusted. [cert], [key]: this
   side's certificate ("" for none). [verify_peer]: the other side must show a certificate signed by the CA. NULL on
   failure, with the reason in [err]. */
SSL_CTX *cph_tls_ctx(int server, const char *ca, const char *cert, const char *key, int verify_peer, char *err,
                     size_t n) {
  SSL_CTX *ctx = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
  if (ctx == NULL) {
    cph_err(err, n, "SSL_CTX_new");
    return NULL;
  }
  const char *what = NULL;
  if (!SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION))
    what = "TLS 1.3";
  else if (SSL_CTX_load_verify_locations(ctx, ca, NULL) != 1)
    what = ca;
  else if (cert[0] != '\0' && SSL_CTX_use_certificate_chain_file(ctx, cert) != 1)
    what = cert;
  else if (cert[0] != '\0' &&
           (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1 || SSL_CTX_check_private_key(ctx) != 1))
    what = key;
  if (what != NULL) {
    cph_err(err, n, what);
    SSL_CTX_free(ctx);
    return NULL;
  }
  SSL_CTX_set_verify(ctx, verify_peer ? (SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT) : SSL_VERIFY_NONE, NULL);
  /* no session tickets: a program keeps its connection; nothing to resume */
  SSL_CTX_set_num_tickets(ctx, 0);
  SSL_CTX_set_mode(ctx, SSL_MODE_AUTO_RETRY);
  return ctx;
}

/* Memory BIOs: OpenSSL never touches the socket and never waits. The caller reads the socket and feeds what came
   ([cph_tls_feed]), takes what OpenSSL wrote ([cph_tls_take]) and sends it, and uses one connection from one thread
   at a time; so the thread that reads requests and the one that sends replies never wait for each other inside
   OpenSSL. */
typedef struct {
  SSL *ssl;
  BIO *in, *out; /* owned by ssl */
} cph_tls;

/* A new connection of [ctx]. A client checks the server's certificate against the CA and [host] (an IP address in
   its subjectAltName, or a DNS name, which is also sent as SNI); "" checks the CA only. NULL on failure. */
cph_tls *cph_tls_new(SSL_CTX *ctx, int server, const char *host, char *err, size_t n) {
  cph_tls *c = malloc(sizeof(cph_tls));
  if (c == NULL) {
    snprintf(err, n, "out of memory");
    return NULL;
  }
  c->ssl = SSL_new(ctx);
  c->in = BIO_new(BIO_s_mem());
  c->out = BIO_new(BIO_s_mem());
  if (c->ssl == NULL || c->in == NULL || c->out == NULL) {
    cph_err(err, n, "SSL_new");
    if (c->ssl) SSL_free(c->ssl);
    if (c->in) BIO_free(c->in);
    if (c->out) BIO_free(c->out);
    free(c);
    return NULL;
  }
  BIO_set_mem_eof_return(c->in, -1);
  SSL_set_bio(c->ssl, c->in, c->out);
  if (server)
    SSL_set_accept_state(c->ssl);
  else {
    SSL_set_connect_state(c->ssl);
    if (host[0] != '\0') {
      X509_VERIFY_PARAM *p = SSL_get0_param(c->ssl);
      if (X509_VERIFY_PARAM_set1_ip_asc(p, host) != 1) {
        ERR_clear_error();
        if (SSL_set1_host(c->ssl, host) != 1 || SSL_set_tlsext_host_name(c->ssl, host) != 1) {
          cph_err(err, n, "the server's name");
          SSL_free(c->ssl);
          free(c);
          return NULL;
        }
      }
    }
  }
  return c;
}

void cph_tls_free(cph_tls *c) {
  if (c != NULL) {
    SSL_free(c->ssl);
    free(c);
  }
}

/* the reason of a failed handshake, read or write: the certificate's, else OpenSSL's queue */
static void cph_conn_err(cph_tls *c, char *err, size_t n, const char *what) {
  long v = SSL_get_verify_result(c->ssl);
  if (v != X509_V_OK) {
    snprintf(err, n, "%s: %s", what, X509_verify_cert_error_string(v));
    ERR_clear_error();
  } else
    cph_err(err, n, what);
}

/* One step of the handshake: 1 once it is done; 0: it needs bytes from the peer; -1: it failed. */
int cph_tls_handshake(cph_tls *c, char *err, size_t n) {
  int r = SSL_do_handshake(c->ssl);
  if (r == 1) return 1;
  if (SSL_get_error(c->ssl, r) == SSL_ERROR_WANT_READ) return 0;
  cph_conn_err(c, err, n, "the TLS handshake");
  return -1;
}

/* [len] bytes from the peer, given to OpenSSL: 0, or -1 (out of memory) */
int cph_tls_feed(cph_tls *c, const unsigned char *p, int len) {
  if (len <= 0) return 0;
  return BIO_write(c->in, p, len) == len ? 0 : -1;
}

/* bytes OpenSSL wrote for the peer, at most [len]: their count */
int cph_tls_take(cph_tls *c, unsigned char *p, int len) {
  if (len <= 0 || BIO_ctrl_pending(c->out) == 0) return 0;
  int k = BIO_read(c->out, p, len);
  return k > 0 ? k : 0;
}

long cph_tls_pending(cph_tls *c) { return (long)BIO_ctrl_pending(c->out); }

/* at most [len] plain bytes (len > 0): their count; 0: more bytes from the peer are needed; -1: the peer closed;
   -2: an error */
int cph_tls_read(cph_tls *c, unsigned char *p, int len, char *err, size_t n) {
  if (len <= 0) return 0;
  int r = SSL_read(c->ssl, p, len);
  if (r > 0) return r;
  int e = SSL_get_error(c->ssl, r);
  if (e == SSL_ERROR_WANT_READ) return 0;
  if (e == SSL_ERROR_ZERO_RETURN) return -1;
  cph_conn_err(c, err, n, "TLS read");
  return -2;
}

/* [len] plain bytes, all of them, encrypted into OpenSSL's output (a memory BIO takes everything): 0, or -1 */
int cph_tls_write(cph_tls *c, const unsigned char *p, int len, char *err, size_t n) {
  int done = 0;
  while (done < len) {
    int r = SSL_write(c->ssl, p + done, len - done);
    if (r <= 0) {
      cph_conn_err(c, err, n, "TLS write");
      return -1;
    }
    done += r;
  }
  return 0;
}

/* the subject's common name of the peer's verified certificate, or "" */
void cph_tls_peer_name(cph_tls *c, char *name, size_t n) {
  name[0] = '\0';
  X509 *x = SSL_get1_peer_certificate(c->ssl);
  if (x != NULL) {
    if (SSL_get_verify_result(c->ssl) == X509_V_OK)
      X509_NAME_get_text_by_NID(X509_get_subject_name(x), NID_commonName, name, (int)n);
    X509_free(x);
  }
}

/* a close_notify for the peer (to be taken and sent) */
void cph_tls_close(cph_tls *c) {
  SSL_shutdown(c->ssl);
  ERR_clear_error();
}

/* ---- certificates ---- */

static EVP_PKEY *read_key(const char *path) {
  FILE *f = fopen(path, "r");
  if (f == NULL) return NULL;
  EVP_PKEY *k = PEM_read_PrivateKey(f, NULL, NULL, NULL);
  fclose(f);
  return k;
}

static X509 *read_cert(const char *path) {
  FILE *f = fopen(path, "r");
  if (f == NULL) return NULL;
  X509 *c = PEM_read_X509(f, NULL, NULL, NULL);
  fclose(f);
  return c;
}

static int add_ext(X509 *cert, X509 *issuer, int nid, const char *v) {
  X509V3_CTX ctx;
  X509V3_set_ctx_nodb(&ctx);
  X509V3_set_ctx(&ctx, issuer, cert, NULL, NULL, 0);
  X509_EXTENSION *e = X509V3_EXT_conf_nid(NULL, &ctx, nid, v);
  if (e == NULL) return 0;
  int ok = X509_add_ext(cert, e, -1);
  X509_EXTENSION_free(e);
  return ok;
}

/* A certificate for the key [k], valid [days] from now, with a random 128-bit serial: a self-signed CA (issuer NULL:
   basicConstraints CA:TRUE, keyCertSign), or one signed by [issuer] and its key [ik] for [cn], with [san] as its
   subjectAltName ("DNS:srv1,IP:10.0.1.11"; "" for none), for servers and clients alike. NULL on failure. */
X509 *cph_tls_cert(EVP_PKEY *k, X509 *issuer, EVP_PKEY *ik, const char *cn, const char *san, int days) {
  X509 *c = X509_new();
  if (c == NULL) return NULL;
  unsigned char serial[16];
  int ok = RAND_bytes(serial, sizeof serial) == 1;
  serial[0] &= 0x7F;
  BIGNUM *bn = BN_bin2bn(serial, sizeof serial, NULL);
  ASN1_INTEGER *sn = bn == NULL ? NULL : BN_to_ASN1_INTEGER(bn, NULL);
  ok = ok && sn != NULL && X509_set_version(c, 2) && X509_set_serialNumber(c, sn) &&
       X509_gmtime_adj(X509_getm_notBefore(c), -300) &&
       X509_gmtime_adj(X509_getm_notAfter(c), (long)days * 86400L) && X509_set_pubkey(c, k);
  ASN1_INTEGER_free(sn);
  BN_free(bn);
  X509_NAME *name = X509_get_subject_name(c);
  ok = ok && X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8, (const unsigned char *)cn, -1, -1, 0);
  ok = ok && X509_set_issuer_name(c, issuer == NULL ? name : X509_get_subject_name(issuer));
  if (issuer == NULL) {
    ok = ok && add_ext(c, c, NID_basic_constraints, "critical,CA:TRUE") &&
         add_ext(c, c, NID_key_usage, "critical,keyCertSign,cRLSign") &&
         add_ext(c, c, NID_subject_key_identifier, "hash");
  } else {
    ok = ok && add_ext(c, issuer, NID_basic_constraints, "critical,CA:FALSE") &&
         add_ext(c, issuer, NID_key_usage, "critical,digitalSignature") &&
         add_ext(c, issuer, NID_ext_key_usage, "serverAuth,clientAuth") &&
         add_ext(c, issuer, NID_subject_key_identifier, "hash") &&
         add_ext(c, issuer, NID_authority_key_identifier, "keyid:always") &&
         (san[0] == '\0' || add_ext(c, issuer, NID_subject_alt_name, san));
  }
  ok = ok && X509_sign(c, issuer == NULL ? k : ik, EVP_sha256()) > 0;
  if (!ok) {
    X509_free(c);
    return NULL;
  }
  return c;
}

/* the key file is made readable by its owner only, before any byte of the key is in it */
static int write_key(const char *path, EVP_PKEY *k) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (fd < 0) return 0;
  FILE *f = fdopen(fd, "w");
  if (f == NULL) {
    close(fd);
    return 0;
  }
  int ok = PEM_write_PrivateKey(f, k, NULL, NULL, 0, NULL, NULL);
  ok = (fflush(f) == 0 && fsync(fd) == 0) && ok;
  fclose(f);
  return ok;
}

static int write_cert(const char *path, X509 *c) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
  if (fd < 0) return 0;
  FILE *f = fdopen(fd, "w");
  if (f == NULL) {
    close(fd);
    return 0;
  }
  int ok = PEM_write_X509(f, c);
  ok = (fflush(f) == 0 && fsync(fd) == 0) && ok;
  fclose(f);
  return ok;
}

/* A new ECDSA P-256 key and its certificate (cph_tls_cert), written to [key_path] and [cert_path], which are made,
   never replaced; [ca_cert] "" makes a self-signed CA, else the CA's certificate and key sign it. 0, or -1 with the
   reason in [err]. */
int cph_tls_make_cert(const char *ca_cert, const char *ca_key, const char *cn, const char *san, int days,
                      const char *key_path, const char *cert_path, char *err, size_t n) {
  EVP_PKEY *k = EVP_EC_gen("P-256");
  if (k == NULL) {
    cph_err(err, n, "the key");
    return -1;
  }
  X509 *issuer = NULL;
  EVP_PKEY *ik = NULL;
  if (ca_cert[0] != '\0') {
    issuer = read_cert(ca_cert);
    ik = read_key(ca_key);
    if (issuer == NULL || ik == NULL) {
      EVP_PKEY_free(k);
      if (issuer) X509_free(issuer);
      if (ik) EVP_PKEY_free(ik);
      cph_err(err, n, "the CA's certificate or key");
      return -1;
    }
  }
  X509 *c = cph_tls_cert(k, issuer, ik, cn, san, days);
  int ok = c != NULL && write_key(key_path, k) && write_cert(cert_path, c);
  if (c) X509_free(c);
  EVP_PKEY_free(k);
  if (issuer) X509_free(issuer);
  if (ik) EVP_PKEY_free(ik);
  if (!ok) {
    cph_err(err, n, "the certificate (do its files exist already?)");
    return -1;
  }
  return 0;
}

/* ==== the OCaml wrappers ==== */

#ifndef CEPHEUS_TLS_CORE_ONLY

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#define Ctx_val(v) (*((SSL_CTX **)Data_custom_val(v)))
#define Conn_val(v) (*((cph_tls **)Data_custom_val(v)))

static void ctx_finalize(value v) {
  if (Ctx_val(v) != NULL) SSL_CTX_free(Ctx_val(v));
}

static void conn_finalize(value v) { cph_tls_free(Conn_val(v)); }

static struct custom_operations ctx_ops = {"cepheus.tls.ctx", ctx_finalize, custom_compare_default,
                                           custom_hash_default, custom_serialize_default,
                                           custom_deserialize_default, custom_compare_ext_default,
                                           custom_fixed_length_default};

static struct custom_operations conn_ops = {"cepheus.tls.conn", conn_finalize, custom_compare_default,
                                            custom_hash_default, custom_serialize_default,
                                            custom_deserialize_default, custom_compare_ext_default,
                                            custom_fixed_length_default};

CAMLprim value cepheus_tls_ctx(value server, value ca, value cert, value key, value verify_peer) {
  CAMLparam5(server, ca, cert, key, verify_peer);
  CAMLlocal1(r);
  char err[512];
  SSL_CTX *ctx = cph_tls_ctx(Bool_val(server), String_val(ca), String_val(cert), String_val(key),
                             Bool_val(verify_peer), err, sizeof err);
  if (ctx == NULL) caml_failwith(err);
  r = caml_alloc_custom(&ctx_ops, sizeof(SSL_CTX *), 0, 1);
  Ctx_val(r) = ctx;
  CAMLreturn(r);
}

CAMLprim value cepheus_tls_conn(value vctx, value server, value host) {
  CAMLparam3(vctx, server, host);
  CAMLlocal1(r);
  char err[512];
  cph_tls *c = cph_tls_new(Ctx_val(vctx), Bool_val(server), String_val(host), err, sizeof err);
  if (c == NULL) caml_failwith(err);
  r = caml_alloc_custom(&conn_ops, sizeof(cph_tls *), 0, 1);
  Conn_val(r) = c;
  CAMLreturn(r);
}

/* the computation (key exchange, signatures: milliseconds) runs without the runtime lock; [vc] stays alive (a
   parameter) and its block does not move (a custom block holds only the pointer, which is read before) */
CAMLprim value cepheus_tls_handshake(value vc) {
  CAMLparam1(vc);
  cph_tls *c = Conn_val(vc);
  char err[512];
  caml_release_runtime_system();
  int r = cph_tls_handshake(c, err, sizeof err);
  caml_acquire_runtime_system();
  if (r < 0) caml_failwith(err);
  CAMLreturn(Val_bool(r == 1));
}

CAMLprim value cepheus_tls_feed(value vc, value buf, value ofs, value len) {
  if (cph_tls_feed(Conn_val(vc), Bytes_val(buf) + Long_val(ofs), (int)Long_val(len)) != 0) caml_failwith("BIO_write");
  return Val_unit;
}

CAMLprim value cepheus_tls_take(value vc, value buf, value ofs, value len) {
  return Val_int(cph_tls_take(Conn_val(vc), Bytes_val(buf) + Long_val(ofs), (int)Long_val(len)));
}

CAMLprim value cepheus_tls_pending(value vc) { return Val_long(cph_tls_pending(Conn_val(vc))); }

CAMLprim value cepheus_tls_read(value vc, value buf, value ofs, value len) {
  char err[512];
  int r = cph_tls_read(Conn_val(vc), Bytes_val(buf) + Long_val(ofs), (int)Long_val(len), err, sizeof err);
  if (r == -2) caml_failwith(err);
  return Val_int(r);
}

CAMLprim value cepheus_tls_write(value vc, value buf, value ofs, value len) {
  char err[512];
  if (cph_tls_write(Conn_val(vc), Bytes_val(buf) + Long_val(ofs), (int)Long_val(len), err, sizeof err) != 0)
    caml_failwith(err);
  return Val_unit;
}

CAMLprim value cepheus_tls_peer_name(value vc) {
  CAMLparam1(vc);
  char name[256];
  cph_tls_peer_name(Conn_val(vc), name, sizeof name);
  CAMLreturn(caml_copy_string(name));
}

CAMLprim value cepheus_tls_close(value vc) {
  cph_tls_close(Conn_val(vc));
  return Val_unit;
}

/* the strings are copied before the runtime lock is released: the GC may move OCaml's */
CAMLprim value cepheus_tls_make_cert(value ca_cert, value ca_key, value cn, value san, value days, value paths) {
  CAMLparam5(ca_cert, ca_key, cn, san, days);
  CAMLxparam1(paths);
  char err[512];
  char *s[6] = {strdup(String_val(ca_cert)), strdup(String_val(ca_key)), strdup(String_val(cn)),
                strdup(String_val(san)), strdup(String_val(Field(paths, 0))), strdup(String_val(Field(paths, 1)))};
  int r = -1;
  if (s[0] && s[1] && s[2] && s[3] && s[4] && s[5]) {
    int d = Int_val(days);
    caml_release_runtime_system();
    r = cph_tls_make_cert(s[0], s[1], s[2], s[3], d, s[4], s[5], err, sizeof err);
    caml_acquire_runtime_system();
  } else
    snprintf(err, sizeof err, "out of memory");
  for (int i = 0; i < 6; i++) free(s[i]);
  if (r != 0) caml_failwith(err);
  CAMLreturn(Val_unit);
}

CAMLprim value cepheus_tls_make_cert_bc(value *argv, int argn) {
  (void)argn;
  return cepheus_tls_make_cert(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}

#endif
