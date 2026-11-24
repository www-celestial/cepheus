/* The monotonic clock (clock_gettime with CLOCK_MONOTONIC, which a change of the wall clock does not move), in
   milliseconds: an immediate int, no allocation, no release of the runtime (a vDSO call on Linux, about 20 ns). For a
   question's deadline (src/query.ml), Raft's timeouts and leases (server/raft.ml). And a wait for a descriptor to be
   readable, with a timeout (poll(2), which has no bound on the descriptor's number, unlike select's FD_SETSIZE), the
   runtime released meanwhile: the keep-alive of the questions' helpers (src/pool.ml). */

#define CAML_NAME_SPACE
#include <poll.h>
#include <time.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

value cepheus_monotonic_ms(value unit) {
  (void)unit;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return Val_long((long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* true when [fd] is readable within [ms] milliseconds; false at the timeout, or when the wait was interrupted */
value cepheus_wait_readable(value fd, value ms) {
  struct pollfd p;
  int r;
  p.fd = Int_val(fd);
  p.events = POLLIN;
  p.revents = 0;
  caml_enter_blocking_section();
  r = poll(&p, 1, Int_val(ms));
  caml_leave_blocking_section();
  return Val_bool(r > 0);
}
