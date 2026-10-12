# The phone build variant

[Finch Phone](https://github.com/calebtrueman/finch-phone) runs Finch's userland on Android
phone hardware, on a Linux kernel, through a Darwin personality (`finch-run`). The binaries
are the same sources as the Mac/VM image, built a little differently:

```
FINCH_VARIANT=phone tools/build-system.sh <steps>     # into build/root-phone
```

| | Mac/VM build | `FINCH_VARIANT=phone` |
|---|---|---|
| Architecture | arm64e | **arm64**: the phone's Cortex-A76/A55 cores have no pointer authentication |
| Thread TSD base | TPIDRRO_EL0 | **TPIDR_EL0** (`FINCH_LINUX_TSD`): Linux doesn't let user code set TPIDRRO_EL0 |
| CPU number (`_os_cpu_number`) | TPIDR_EL0 low bits | always 0 |
| Output | `build/root`, `build/obj`, `build/logs`, … | `build/root-phone`, `build/obj-phone`, `build/logs-phone`, … |

`tools/variant.sh`, and its make twin `userland/variant.mk`, define the variant in one place:
`FINCH_ARCH`, `FINCH_VARIANT_CFLAGS` and the directory suffix `V`. `tools/build-oss.sh`
passes them to Xcode (`ARCHS`, `GCC_PREPROCESSOR_DEFINITIONS`, `FINCH_V`) and to recipes.
With `FINCH_VARIANT` unset, every build is unchanged.

`FINCH_LINUX_TSD` touches three places, all guarded so the Mac build compiles exactly as before:

- XNU `libsyscall/os/tsd.h` and `os/x18.c` (`kernel/patches/0007`). The header reaches every
  project through the SDK overlay.
- libpthread `src/pthread_asm.s` (`userland/patches/libpthread/0002`).
- dyld `libdyld/threadLocalHelpers.s` (`userland/patches/dyld/0004`).

Linking arm64 against the macOS SDK's arm64e-only stubs is normal: every arm64 Mac program
does it. Libsystem's pre-link check didn't allow it, so `userland/patches/Libsystem/0001`
lets it.

## Coverage

`tools/build-system.sh` builds only the steps in its `phone_steps` list for the phone
variant: libSystem and its ~40 sub-libraries, the LLVM runtimes and dyld. Other steps are
refused until their build files honour the variant. Extend the list as Finch Phone needs
frameworks.
