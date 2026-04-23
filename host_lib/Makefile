# Build a host-side static library (libattoio.a) and a compile-only
# smoke test to prove the headers parse cleanly on common compilers.
#
# Intended use from a host SoC's firmware build system:
#   cc -I/path/to/attoio/host_lib/ libattoio.c
#   include "libattoio.h"

CC      ?= cc
CFLAGS  ?= -Wall -Wextra -Werror -O2 -std=c11 -I.
AR      ?= ar

all: libattoio.a host_smoke_test

libattoio.o: libattoio.c libattoio.h ../sw/common/attoio_rpc.h
	$(CC) $(CFLAGS) -c $< -o $@

libattoio.a: libattoio.o
	$(AR) rcs $@ $<

host_smoke_test: host_smoke_test.c libattoio.a
	$(CC) $(CFLAGS) $< libattoio.a -o $@

smoke: host_smoke_test
	./host_smoke_test

clean:
	rm -f *.o libattoio.a host_smoke_test

.PHONY: all smoke clean
