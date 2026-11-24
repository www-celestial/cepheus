/* What OCaml's Unix lacks for local readers (docs/book/server.md, "Local reads"): sending open file descriptors to
   another process over a Unix-domain socket and receiving them (sendmsg and recvmsg with one SCM_RIGHTS control
   message, unix(7)), and mapping a file's first page read-only and shared (mmap with PROT_READ and MAP_SHARED: the
   server's later stores to the page are seen at once, and the reader cannot write it). The interface is
   server/fdpass.ml, which checks every offset and length before a call. And whether the peer of a socket has closed
   it (poll with POLLRDHUP), so that a question whose program is gone stops (server/core.ml). */

/* POLLRDHUP */
#define _GNU_SOURCE
#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

#define MAX_FDS 64

/* [len] bytes of [buf] from [ofs], with the descriptors of the array [fds] (at most MAX_FDS) attached to their first
   byte: the count of bytes sent (the caller sends the rest without descriptors) */
CAMLprim value cepheus_fd_send(value sock, value buf, value ofs, value len, value fds) {
  CAMLparam5(sock, buf, ofs, len, fds);
  int n = (int)Wosize_val(fds);
  if (n > MAX_FDS) caml_invalid_argument("Fdpass.send: too many descriptors");
  /* the bytes are copied out of the OCaml heap: the runtime lock is released during the call */
  size_t l = Long_val(len);
  char stack[4096];
  char *copy = l <= sizeof stack ? stack : malloc(l);
  if (copy == NULL) caml_raise_out_of_memory();
  memcpy(copy, Bytes_val(buf) + Long_val(ofs), l);
  struct iovec iov = {copy, l};
  union {
    char buf[CMSG_SPACE(sizeof(int) * MAX_FDS)];
    struct cmsghdr align;
  } ctl;
  struct msghdr msg;
  memset(&msg, 0, sizeof msg);
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  if (n > 0) {
    memset(ctl.buf, 0, sizeof ctl.buf);
    msg.msg_control = ctl.buf;
    msg.msg_controllen = CMSG_SPACE(sizeof(int) * n);
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int) * n);
    int *p = (int *)CMSG_DATA(c);
    for (int i = 0; i < n; i++) p[i] = Int_val(Field(fds, i));
  }
  int s = Int_val(sock);
  caml_enter_blocking_section();
  ssize_t r = sendmsg(s, &msg, MSG_NOSIGNAL);
  int e = errno;
  caml_leave_blocking_section();
  if (copy != stack) free(copy);
  if (r < 0) caml_unix_error(e, "sendmsg", Nothing);
  CAMLreturn(Val_long(r));
}

/* at most [len] bytes into [buf] from [ofs], and the descriptors that came with them (close-on-exec): (count, fds).
   Descriptors cut off by a control buffer too small (more than MAX_FDS) are closed, and the call fails. */
CAMLprim value cepheus_fd_recv(value sock, value buf, value ofs, value len) {
  CAMLparam4(sock, buf, ofs, len);
  CAMLlocal2(arr, res);
  size_t l = Long_val(len);
  char stack[65536];
  char *copy = l <= sizeof stack ? stack : malloc(l);
  if (copy == NULL) caml_raise_out_of_memory();
  struct iovec iov = {copy, l};
  union {
    char buf[CMSG_SPACE(sizeof(int) * MAX_FDS)];
    struct cmsghdr align;
  } ctl;
  struct msghdr msg;
  memset(&msg, 0, sizeof msg);
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = ctl.buf;
  msg.msg_controllen = sizeof ctl.buf;
  int s = Int_val(sock);
  caml_enter_blocking_section();
  ssize_t r = recvmsg(s, &msg, MSG_CMSG_CLOEXEC);
  int e = errno;
  caml_leave_blocking_section();
  if (r < 0) {
    if (copy != stack) free(copy);
    caml_unix_error(e, "recvmsg", Nothing);
  }
  int got[MAX_FDS], n = 0;
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
      int k = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
      int *p = (int *)CMSG_DATA(c);
      for (int i = 0; i < k; i++) {
        if (n < MAX_FDS)
          got[n++] = p[i];
        else
          close(p[i]);
      }
    }
  }
  if (msg.msg_flags & MSG_CTRUNC) {
    for (int i = 0; i < n; i++) close(got[i]);
    if (copy != stack) free(copy);
    caml_failwith("Fdpass.recv: more descriptors than a message may carry");
  }
  memcpy(Bytes_val(buf) + Long_val(ofs), copy, r);
  if (copy != stack) free(copy);
  arr = caml_alloc_tuple(n); /* Atom(0) for none */
  for (int i = 0; i < n; i++) Store_field(arr, i, Val_int(got[i]));
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_long(r));
  Store_field(res, 1, arr);
  CAMLreturn(res);
}

/* the first [len] bytes of the file of [fd] mapped read-only and shared, as a Bigarray of 64-bit integers; never
   unmapped (Fdpass keeps one mapping a file for the process) */
CAMLprim value cepheus_fd_map_ro(value fd, value len) {
  CAMLparam2(fd, len);
  size_t l = Long_val(len);
  void *p = mmap(NULL, l, PROT_READ, MAP_SHARED, Int_val(fd), 0);
  if (p == MAP_FAILED) caml_unix_error(errno, "mmap", Nothing);
  CAMLreturn(caml_ba_alloc_dims(CAML_BA_INT64 | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL, 1, p, (intnat)(l / 8)));
}

/* Has the peer closed the socket (or the connection broken): poll(2) with no timeout for POLLRDHUP, the peer's
   shutdown of its side (Linux 2.6.17, TCP and Unix stream sockets), with POLLHUP and POLLERR; bytes the peer sent
   before do not hide it. As PostgreSQL's client_connection_check_interval (WL_SOCKET_CLOSED). An immediate bool, no
   allocation, no release of the runtime: the call does not wait. */
value cepheus_peer_closed(value fd) {
  struct pollfd p;
  p.fd = Int_val(fd);
#ifdef POLLRDHUP
  p.events = POLLRDHUP;
#else
  p.events = 0;
#endif
  p.revents = 0;
  if (poll(&p, 1, 0) <= 0) return Val_false;
  return Val_bool((p.revents & (POLLHUP | POLLERR | POLLNVAL
#ifdef POLLRDHUP
                                | POLLRDHUP
#endif
                                )) != 0);
}
