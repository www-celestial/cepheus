/* TLS 1.3 by OpenSSL 3, the system's libssl (security fixes come with the system's updates): contexts, a handshake
   on a blocking socket, reads and writes, the peer's verified name, and the certificates of a cluster (an ECDSA
   P-256 CA, and certificates it signs). Every call that waits or computes (handshakes, reads, writes, key
   generation) releases the OCaml runtime lock; bytes cross through C buffers, since the GC may move OCaml's.
   The interface is server/tls.mli; nothing here parses a protocol: OpenSSL does. */

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* the first error of OpenSSL's queue, or [what] */
static void tls_fail(const char *what) {
  char buf[512];
  unsigned long e = ERR_get_error();
  if (e != 0) {
    char reason[256];
    ERR_error_string_n(e, reason, sizeof reason);
    snprintf(buf, sizeof buf, "%s: %s", what, reason);
  } else
    snprintf(buf, sizeof buf, "%s", what);
  ERR_clear_error();
  caml_failwith(buf);
}

/* ---- contexts ---- */

#define Ctx_val(v) (*((SSL_CTX **)Data_custom_val(v)))

static void ctx_finalize(value v) {
  if (Ctx_val(v) != NULL) SSL_CTX_free(Ctx_val(v));
}

static struct custom_operations ctx_ops = {"cepheus.tls.ctx", ctx_finalize, custom_compare_default,
                                           custom_hash_default, custom_serialize_default,
                                           custom_deserialize_default, custom_compare_ext_default,
                                           custom_fixed_length_default};

/* [server]: 1 for a server's context. [ca]: the cluster's CA, whose certificates are trusted. [cert], [key]: this
   side's certificate ("" for none). [verify_peer]: the other side must show a certificate signed by the CA. */
CAMLprim value cepheus_tls_ctx(value server, value ca, value cert, value key, value verify_peer) {
  CAMLparam5(server, ca, cert, key, verify_peer);
  CAMLlocal1(r);
  SSL_CTX *ctx = SSL_CTX_new(Bool_val(server) ? TLS_server_method() : TLS_client_method());
  if (ctx == NULL) tls_fail("SSL_CTX_new");
  if (!SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION)) {
    SSL_CTX_free(ctx);
    tls_fail("TLS 1.3");
  }
  if (SSL_CTX_load_verify_locations(ctx, String_val(ca), NULL) != 1) {
    SSL_CTX_free(ctx);
    tls_fail(String_val(ca));
  }
  if (caml_string_length(cert) > 0) {
    if (SSL_CTX_use_certificate_chain_file(ctx, String_val(cert)) != 1) {
      SSL_CTX_free(ctx);
      tls_fail(String_val(cert));
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, String_val(key), SSL_FILETYPE_PEM) != 1 || SSL_CTX_check_private_key(ctx) != 1) {
      SSL_CTX_free(ctx);
      tls_fail(String_val(key));
    }
  }
  SSL_CTX_set_verify(ctx, Bool_val(verify_peer) ? (SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT) : SSL_VERIFY_NONE,
                     NULL);
  /* no session tickets: a program keeps its connection; nothing to resume */
  SSL_CTX_set_num_tickets(ctx, 0);
  SSL_CTX_set_mode(ctx, SSL_MODE_AUTO_RETRY);
  r = caml_alloc_custom(&ctx_ops, sizeof(SSL_CTX *), 0, 1);
  Ctx_val(r) = ctx;
  CAMLreturn(r);
}

/* ---- connections ----
   Memory BIOs: OpenSSL never touches the socket and never waits. The OCaml side reads the socket and feeds what
   came ([feed]), takes what OpenSSL wrote ([take]) and sends it, and serializes every call on one connection (an
   SSL object is used by one thread at a time); so the thread that reads requests and the one that sends replies
   never wait for each other inside OpenSSL. */

typedef struct {
  SSL *ssl;
  BIO *in, *out; /* owned by ssl */
} conn;

#define Conn_val(v) (*((conn **)Data_custom_val(v)))

static void conn_finalize(value v) {
  conn *c = Conn_val(v);
  if (c != NULL) {
    SSL_free(c->ssl);
    free(c);
  }
}

static struct custom_operations conn_ops = {"cepheus.tls.conn", conn_finalize, custom_compare_default,
                                            custom_hash_default, custom_serialize_default,
                                            custom_deserialize_default, custom_compare_ext_default,
                                            custom_fixed_length_default};

/* A new connection of [vctx]. A client checks the server's certificate against the CA and [host] (an IP address in
   its subjectAltName, or a DNS name, which is also sent as SNI); "" checks the CA only. */
CAMLprim value cepheus_tls_conn(value vctx, value server, value host) {
  CAMLparam3(vctx, server, host);
  CAMLlocal1(r);
  conn *c = malloc(sizeof(conn));
  if (c == NULL) caml_raise_out_of_memory();
  c->ssl = SSL_new(Ctx_val(vctx));
  c->in = BIO_new(BIO_s_mem());
  c->out = BIO_new(BIO_s_mem());
  if (c->ssl == NULL || c->in == NULL || c->out == NULL) {
    if (c->ssl) SSL_free(c->ssl);
    if (c->in) BIO_free(c->in);
    if (c->out) BIO_free(c->out);
    free(c);
    tls_fail("SSL_new");
  }
  BIO_set_mem_eof_return(c->in, -1);
  SSL_set_bio(c->ssl, c->in, c->out);
  if (Bool_val(server))
    SSL_set_accept_state(c->ssl);
  else {
    SSL_set_connect_state(c->ssl);
    if (caml_string_length(host) > 0) {
      const char *h = String_val(host);
      X509_VERIFY_PARAM *p = SSL_get0_param(c->ssl);
      if (X509_VERIFY_PARAM_set1_ip_asc(p, h) != 1) {
        ERR_clear_error();
        if (SSL_set1_host(c->ssl, h) != 1 || SSL_set_tlsext_host_name(c->ssl, h) != 1) {
          SSL_free(c->ssl);
          free(c);
          tls_fail("the server's name");
        }
      }
    }
  }
  r = caml_alloc_custom(&conn_ops, sizeof(conn *), 0, 1);
  Conn_val(r) = c;
  CAMLreturn(r);
}

static void conn_fail(conn *c, const char *what) {
  char buf[300];
  long v = SSL_get_verify_result(c->ssl);
  if (v != X509_V_OK) {
    snprintf(buf, sizeof buf, "%s: %s", what, X509_verify_cert_error_string(v));
    ERR_clear_error();
    caml_failwith(buf);
  }
  tls_fail(what);
}

/* One step of the handshake: true once it is done; false: it needs bytes from the peer. The computation (key
   exchange, signatures: milliseconds) runs without the runtime lock. */
CAMLprim value cepheus_tls_handshake(value vc) {
  CAMLparam1(vc);
  conn *c = Conn_val(vc);
  int r;
  caml_release_runtime_system();
  r = SSL_do_handshake(c->ssl);
  caml_acquire_runtime_system();
  if (r == 1) CAMLreturn(Val_true);
  int e = SSL_get_error(c->ssl, r);
  if (e == SSL_ERROR_WANT_READ) CAMLreturn(Val_false);
  conn_fail(c, "the TLS handshake");
  CAMLreturn(Val_false);
}

/* bytes from the peer, given to OpenSSL */
CAMLprim value cepheus_tls_feed(value vc, value buf, value ofs, value len) {
  conn *c = Conn_val(vc);
  if (Int_val(len) > 0 && BIO_write(c->in, Bytes_val(buf) + Int_val(ofs), Int_val(len)) != Int_val(len))
    tls_fail("BIO_write");
  return Val_unit;
}

/* bytes OpenSSL wrote for the peer, at most [len]: their count */
CAMLprim value cepheus_tls_take(value vc, value buf, value ofs, value len) {
  conn *c = Conn_val(vc);
  if (BIO_ctrl_pending(c->out) == 0) return Val_int(0);
  int n = BIO_read(c->out, Bytes_val(buf) + Int_val(ofs), Int_val(len));
  return Val_int(n > 0 ? n : 0);
}

CAMLprim value cepheus_tls_pending(value vc) { return Val_long(BIO_ctrl_pending(Conn_val(vc)->out)); }

/* at most [len] bytes of plain data: their count; 0: more bytes from the peer are needed; -1: the peer closed */
CAMLprim value cepheus_tls_read(value vc, value buf, value ofs, value len) {
  conn *c = Conn_val(vc);
  int r = SSL_read(c->ssl, Bytes_val(buf) + Int_val(ofs), Int_val(len));
  if (r > 0) return Val_int(r);
  int e = SSL_get_error(c->ssl, r);
  if (e == SSL_ERROR_WANT_READ) return Val_int(0);
  if (e == SSL_ERROR_ZERO_RETURN) return Val_int(-1);
  conn_fail(c, "TLS read");
  return Val_int(-1);
}

/* plain data, all of it, encrypted into OpenSSL's output (a memory BIO takes everything) */
CAMLprim value cepheus_tls_write(value vc, value buf, value ofs, value len) {
  conn *c = Conn_val(vc);
  int done = 0, total = Int_val(len);
  while (done < total) {
    int r = SSL_write(c->ssl, Bytes_val(buf) + Int_val(ofs) + done, total - done);
    if (r <= 0) conn_fail(c, "TLS write");
    done += r;
  }
  return Val_unit;
}

/* the subject's common name of the peer's verified certificate, or "" */
CAMLprim value cepheus_tls_peer_name(value vc) {
  CAMLparam1(vc);
  char name[256] = "";
  conn *c = Conn_val(vc);
  X509 *x = SSL_get1_peer_certificate(c->ssl);
  if (x != NULL) {
    if (SSL_get_verify_result(c->ssl) == X509_V_OK)
      X509_NAME_get_text_by_NID(X509_get_subject_name(x), NID_commonName, name, sizeof name);
    X509_free(x);
  }
  CAMLreturn(caml_copy_string(name));
}

/* a close_notify for the peer (to be taken and sent) */
CAMLprim value cepheus_tls_close(value vc) {
  SSL_shutdown(Conn_val(vc)->ssl);
  ERR_clear_error();
  return Val_unit;
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

/* A new ECDSA P-256 key and its certificate, valid [days] from now, with a random 128-bit serial. [ca_cert] ""
   makes a self-signed CA (basicConstraints CA:TRUE, keyCertSign); otherwise a certificate signed by the CA for
   [cn], with [san] as its subjectAltName ("DNS:srv1,IP:10.0.1.11"), for servers and clients alike. Files are made,
   never replaced. */
CAMLprim value cepheus_tls_make_cert(value ca_cert, value ca_key, value cn, value san, value days, value paths) {
  CAMLparam5(ca_cert, ca_key, cn, san, days);
  CAMLxparam1(paths);
  const char *key_path = String_val(Field(paths, 0)), *cert_path = String_val(Field(paths, 1));
  int is_ca = caml_string_length(ca_cert) == 0;
  EVP_PKEY *k = EVP_EC_gen("P-256");
  if (k == NULL) tls_fail("the key");
  X509 *issuer = NULL;
  EVP_PKEY *ik = NULL;
  if (!is_ca) {
    issuer = read_cert(String_val(ca_cert));
    ik = read_key(String_val(ca_key));
    if (issuer == NULL || ik == NULL) {
      EVP_PKEY_free(k);
      if (issuer) X509_free(issuer);
      if (ik) EVP_PKEY_free(ik);
      tls_fail("the CA's certificate or key");
    }
  }
  X509 *c = X509_new();
  unsigned char serial[16];
  RAND_bytes(serial, sizeof serial);
  serial[0] &= 0x7F;
  BIGNUM *bn = BN_bin2bn(serial, sizeof serial, NULL);
  ASN1_INTEGER *sn = BN_to_ASN1_INTEGER(bn, NULL);
  int ok = c != NULL && X509_set_version(c, 2) && X509_set_serialNumber(c, sn) &&
           X509_gmtime_adj(X509_getm_notBefore(c), -300) &&
           X509_gmtime_adj(X509_getm_notAfter(c), (long)Int_val(days) * 86400L) && X509_set_pubkey(c, k);
  ASN1_INTEGER_free(sn);
  BN_free(bn);
  X509_NAME *name = X509_get_subject_name(c);
  ok = ok && X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8, (const unsigned char *)String_val(cn), -1, -1, 0);
  ok = ok && X509_set_issuer_name(c, is_ca ? name : X509_get_subject_name(issuer));
  if (is_ca) {
    ok = ok && add_ext(c, c, NID_basic_constraints, "critical,CA:TRUE") &&
         add_ext(c, c, NID_key_usage, "critical,keyCertSign,cRLSign") &&
         add_ext(c, c, NID_subject_key_identifier, "hash");
  } else {
    ok = ok && add_ext(c, issuer, NID_basic_constraints, "critical,CA:FALSE") &&
         add_ext(c, issuer, NID_key_usage, "critical,digitalSignature") &&
         add_ext(c, issuer, NID_ext_key_usage, "serverAuth,clientAuth") &&
         add_ext(c, issuer, NID_subject_key_identifier, "hash") &&
         add_ext(c, issuer, NID_authority_key_identifier, "keyid:always") &&
         (caml_string_length(san) == 0 || add_ext(c, issuer, NID_subject_alt_name, String_val(san)));
  }
  ok = ok && X509_sign(c, is_ca ? k : ik, EVP_sha256()) > 0;
  ok = ok && write_key(key_path, k) && write_cert(cert_path, c);
  if (c) X509_free(c);
  EVP_PKEY_free(k);
  if (issuer) X509_free(issuer);
  if (ik) EVP_PKEY_free(ik);
  if (!ok) tls_fail("the certificate (do its files exist already?)");
  CAMLreturn(Val_unit);
}

CAMLprim value cepheus_tls_make_cert_bc(value *argv, int argn) {
  (void)argn;
  return cepheus_tls_make_cert(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}
