# SPDX-License-Identifier: MIT OR Apache-2.0
# Keep the unfinished library out of the boot image until its checks pass.
FINCH := $(abspath ../../..)
OUT ?= $(FINCH)/build/userland/trace
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -Os -Wall -Wextra -Werror -fblocks -fno-objc-arc \
 -I$(FINCH)/build/sdk/override -I$(FINCH)/build/sdk/availability \
 -idirafter $(FINCH)/build/sdk/include
SOURCES := mode.c diagnostic_stream.c preferences.c format.c format_spi.c stream_entry.c log.c fault.c object.m activity.c util.c backtrace.c blob.c ring.c amfi.c storage.c transport.c state.c control.c rtconnection.c metric.c metric_object.m image.c
HEADERS := internal.h format.h blob.h ring.h transport.h fault.h state.h
TESTS := preferences-compare stream-entry-compare format-spi-compare format-compare log-compare object-compare activity-compare util-compare backtrace-compare blob-compare ring-compare metric-compare state-compare image-compare args-compare
LIB := $(OUT)/libsystem_trace.dylib
all: $(LIB)
$(LIB): $(SOURCES) $(HEADERS) Makefile
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -dynamiclib $(SOURCES) -lobjc -o $@
	codesign -f -s - $@
$(OUT)/%-compare: tests/%-compare.c $(HEADERS)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -o $@
$(OUT)/args-compare: tests/args-compare.m $(HEADERS)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -framework Foundation -o $@
$(OUT)/object-compare: tests/object-compare.m $(HEADERS)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -framework Foundation -o $@
$(OUT)/amfi-wire: tests/amfi-wire.c amfi.c internal.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -o $@
$(OUT)/transport-wire: tests/transport-wire.c transport.c transport.h format.c blob.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< format.c blob.c -o $@
$(OUT)/rtconnection-wire: tests/rtconnection-wire.c rtconnection.c ring.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< ring.c -o $@
$(OUT)/storage-wire: tests/storage-wire.c storage.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -o $@
$(OUT)/control-wire: tests/control-wire.c control.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -o $@
$(OUT)/state-wire.o: state.c state.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Ddebug_control_port_for_pid=test_debug_control_port_for_pid -Dmach_msg=test_state_mach_msg -Dmach_port_deallocate=test_state_port_deallocate -Dvoucher_get_activity_id=test_state_activity_id -D_os_activity_initiate=test_state_activity -c $< -o $@
$(OUT)/state-wire: tests/state-wire.c $(OUT)/state-wire.o
	$(CC) $(CFLAGS) $^ -o $@
check: $(LIB) $(addprefix $(OUT)/,$(TESTS)) $(OUT)/amfi-wire $(OUT)/transport-wire $(OUT)/control-wire $(OUT)/state-wire $(OUT)/rtconnection-wire $(OUT)/storage-wire $(OUT)/preferences-wire $(OUT)/mode-compare $(OUT)/mode-wire $(OUT)/diagnostic-stream-test $(OUT)/fault-test $(OUT)/fault-callbacks
	@set -e; for test in $(TESTS); do $(OUT)/$$test $(LIB); done
	$(OUT)/amfi-wire
	$(OUT)/transport-wire
	$(OUT)/control-wire
	$(OUT)/state-wire
	$(OUT)/rtconnection-wire
	$(OUT)/storage-wire
	$(OUT)/preferences-wire
	python3 tests/mode-env-compare.py $(OUT)/mode-compare $(LIB)
	$(OUT)/mode-wire
	$(OUT)/diagnostic-stream-test
	$(OUT)/fault-test
	$(OUT)/fault-callbacks $(LIB)
.PHONY: all check

$(OUT)/preferences-wire.o: preferences.c preferences.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Dsysctlbyname=test_preferences_sysctl -Dmach_host_self=test_preferences_host_self -Dhost_set_atm_diagnostic_flag=test_preferences_set_flags -Dmach_port_deallocate=test_preferences_port_free -Dnotify_register_dispatch=test_preferences_notify -Dvoucher_get_activity_id=test_preferences_activity -Dvoucher_activity_get_logging_preferences=test_preferences_cache -Dmach_vm_deallocate=test_preferences_vm_free -Dxpc_bundle_create_main=test_preferences_bundle -Dxpc_bundle_get_info_dictionary=test_preferences_bundle_info -D_os_trace_read_file_at=test_preferences_read -Dos_variant_check=test_preferences_variant -Dos_variant_is_recovery=test_preferences_recovery -Dos_variant_has_internal_diagnostics=test_preferences_internal -c $< -o $@
$(OUT)/preferences-wire: tests/preferences-wire.c $(OUT)/preferences-wire.o
	$(CC) $(CFLAGS) $^ -o $@

$(OUT)/mode-compare: tests/mode-compare.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -o $@
$(OUT)/mode-wire.o: mode.c mode.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Dxpc_bundle_create_main=test_mode_bundle -Dxpc_bundle_get_info_dictionary=test_mode_bundle_info -Dvoucher_get_activity_id=test_mode_activity -c $< -o $@
$(OUT)/mode-wire: tests/mode-wire.c $(OUT)/mode-wire.o
	$(CC) $(CFLAGS) $^ -o $@
$(OUT)/diagnostic-stream-test: tests/diagnostic-stream-test.c diagnostic_stream.c stream_entry.c
	$(CC) $(CFLAGS) $^ -o $@
$(OUT)/fault-test: tests/fault-test.c fault.c fault.h state.h internal.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) tests/fault-test.c fault.c -o $@
$(OUT)/fault-callbacks: tests/fault-callbacks.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $< -o $@
