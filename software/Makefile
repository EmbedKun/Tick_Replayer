ifeq ($(origin CXX),default)
CXX := $(shell command -v g++-9 2>/dev/null || command -v g++-7 2>/dev/null || command -v g++)
endif
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -pedantic -pthread
LDLIBS ?=

PREFIX ?= /usr/local
LIBEXECDIR ?= $(PREFIX)/lib/tick-replayer
DESTDIR ?=

.PHONY: all clean install

all: xdma_stream_ring_fast xdma_h2c_bench

xdma_stream_ring_fast: xdma_stream_ring_fast.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDLIBS)

xdma_h2c_bench: xdma_h2c_bench.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f xdma_stream_ring_fast xdma_h2c_bench

install: all
	install -d $(DESTDIR)$(LIBEXECDIR) $(DESTDIR)$(PREFIX)/bin
	install -m 644 *.py $(DESTDIR)$(LIBEXECDIR)/
	install -m 755 xdma_stream_ring_fast xdma_h2c_bench $(DESTDIR)$(LIBEXECDIR)/
	install -m 755 tick-replay $(DESTDIR)$(PREFIX)/bin/tick-replay
