#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

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
