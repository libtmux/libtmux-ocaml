#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <stdint.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

CAMLprim value libtmux_poll(value readers, value writers, value timeout) {
  CAMLparam3(readers, writers, timeout);
  size_t count = 0, index = 0;
  /* The private engine watches at most two pipes per lane, a pidfd and a
     cancellation pipe. Keep this on the stack: entering or leaving a blocking
     section can run a signal handler that raises. */
  struct pollfd items[64];
  value cursor;
  double seconds = Double_val(timeout);
  if (isnan(seconds)) caml_invalid_argument("poll: NaN timeout");
  for (cursor = readers; cursor != Val_emptylist; cursor = Field(cursor, 1))
    count++;
  for (cursor = writers; cursor != Val_emptylist; cursor = Field(cursor, 1))
    count++;
  if (count > sizeof(items) / sizeof(items[0]))
    caml_invalid_argument("poll: too many watched descriptors");
  for (cursor = readers; cursor != Val_emptylist; cursor = Field(cursor, 1))
    items[index++] = (struct pollfd){ .fd = Int_val(Field(cursor, 0)), .events = POLLIN };
  for (cursor = writers; cursor != Val_emptylist; cursor = Field(cursor, 1))
    items[index++] = (struct pollfd){ .fd = Int_val(Field(cursor, 0)), .events = POLLOUT };
  int milliseconds = seconds < 0 ? -1 :
    seconds >= (double)INT_MAX / 1000 ? INT_MAX : (int)ceil(seconds * 1000);

  /* No pointers into OCaml values survive the released domain lock. */
  caml_enter_blocking_section();
  int result = poll(items, count, milliseconds);
  int error = result < 0 ? errno : 0;
  if (result > 0) {
    for (size_t i = 0; i < count; i++) {
      if (items[i].revents & POLLNVAL) { error = EBADF; break; }
    }
  }
  caml_leave_blocking_section();
  if (error) caml_unix_error(error, "poll", Nothing);
  CAMLreturn(Val_bool(result > 0));
}

CAMLprim value libtmux_pidfd_open(value pid) {
  int fd = syscall(SYS_pidfd_open, Long_val(pid), 0);
  if (fd < 0) caml_uerror("pidfd_open", Nothing);
  return Val_int(fd);
}

CAMLprim value libtmux_pidfd_alive(value fd) {
  struct pollfd item = { .fd = Int_val(fd), .events = POLLIN };
  int count;
  do { count = poll(&item, 1, 0); } while (count < 0 && errno == EINTR);
  if (count < 0) caml_uerror("poll(pidfd)", Nothing);
  if (item.revents & POLLNVAL) caml_unix_error(EBADF, "poll(pidfd)", Nothing);
  return Val_bool(count == 0);
}

CAMLprim value libtmux_monotonic_ns(value unit) {
  CAMLparam1(unit);
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    caml_uerror("clock_gettime", Nothing);
  CAMLreturn(caml_copy_int64((int64_t)now.tv_sec * 1000000000 + now.tv_nsec));
}

CAMLprim value libtmux_random_bytes(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(result);
  unsigned char bytes[32];
  size_t offset = 0;
  while (offset < sizeof(bytes)) {
    ssize_t count = getrandom(bytes + offset, sizeof(bytes) - offset, GRND_NONBLOCK);
    if (count < 0) {
      if (errno == EINTR) continue;
      caml_uerror("getrandom", Nothing);
    }
    offset += (size_t)count;
  }
  result = caml_alloc_initialized_string(sizeof(bytes), (const char *)bytes);
  CAMLreturn(result);
}
