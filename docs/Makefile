SRCDIR:=$(shell dirname $(abspath $(firstword $(MAKEFILE_LIST))))

default: liveserver

liveserver:
	julia --project=${SRCDIR} ${SRCDIR}/liveserver.jl

clean:
	julia ${SRCDIR}/clean.jl

.PHONY: default liveserver clean
