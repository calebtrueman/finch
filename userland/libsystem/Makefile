# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's replacements for closed libSystem libraries (docs/design/PHASE1-EXIT.md).
LIBS := featureflags coreservices darwindirectory eligibility symptoms trial secinit sanitizers rosetta quarantine cache containermanager networkextension sandbox
TESTED := featureflags coreservices quarantine cache containermanager networkextension sandbox

all:
	@for l in $(LIBS); do $(MAKE) -s -C $$l || exit 1; done

test: all
	@for l in $(TESTED); do $(MAKE) -s -C $$l test || exit 1; done

clean:
	@for l in $(LIBS); do $(MAKE) -s -C $$l clean; done

.PHONY: all test clean
