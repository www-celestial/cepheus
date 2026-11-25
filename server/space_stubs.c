/* The room of a file system (statvfs(3)): the bytes free for the server's user (f_bavail, not the blocks kept for
   root) and the size, both in f_frsize units; for cepheus status (server/space.ml). */

#define CAML_NAME_SPACE
#include <errno.h>
#include <sys/statvfs.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

value cepheus_statvfs(value path) {
  CAMLparam1(path);
  CAMLlocal1(r);
  struct statvfs s;
  char *p = caml_stat_strdup(String_val(path));
  int k;
  caml_enter_blocking_section();
  k = statvfs(p, &s);
  caml_leave_blocking_section();
  caml_stat_free(p);
  if (k != 0) uerror("statvfs", path);
  r = caml_alloc_tuple(2);
  Store_field(r, 0, Val_long((long)(s.f_bavail * s.f_frsize)));
  Store_field(r, 1, Val_long((long)(s.f_blocks * s.f_frsize)));
  CAMLreturn(r);
}
