# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's PAM pieces, on Apple's OpenPAM and pam_modules (tools/build-system.sh):
#  - pam_unix.so.2, built from OpenPAM's own pam_unix (BSD; build/src/OpenPAM).
#    Apple doesn't ship it; it stands in for pam_opendirectory, which needs the
#    closed OpenDirectory.
#  - /etc/pam.d stacks that use only the modules Finch has. They replace the
#    ones pam_modules installs.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Werror -Wno-unused-parameter
SRC   := $(FINCH)/build/src/OpenPAM/openpam/modules/pam_unix/pam_unix.c
MOD   := $(ROOT)/usr/lib/pam/pam_unix.so.2
CONFS := $(notdir $(wildcard pam.d/*))

all: $(MOD) $(addprefix $(ROOT)/private/etc/pam.d/,$(CONFS))

$(MOD): $(SRC)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -dynamiclib -install_name /usr/lib/pam/pam_unix.so.2 -o $@ $< \
	    -L$(ROOT)/usr/lib -lpam
	codesign -f -s - -i org.openpam.pam_unix $@

# Always reinstalled: pam_modules installs Apple's stacks over these (they name
# closed modules), and theirs can be newer than Finch's sources.
$(ROOT)/private/etc/pam.d/%: pam.d/% FORCE
	@mkdir -p $(dir $@)
	install -m 644 $< $@

FORCE:
.PHONY: all FORCE
