ifeq ($(origin CXX),default)
CXX := $(shell command -v g++-9 2>/dev/null || command -v g++-7 2>/dev/null || command -v g++)
endif
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -pedantic -pthread
LDLIBS ?=

.PHONY: all clean

all: xdma_stream_ring_fast

xdma_stream_ring_fast: xdma_stream_ring_fast.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f xdma_stream_ring_fast
