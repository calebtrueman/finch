# Kernel

- `xnu/`: pristine Apple source, a submodule pinned to `xnu-12377.101.15`. Never edit it
  directly.
- `patches/`: Finch's changes, applied in order by `tools/build-kernel.sh` to a working
  copy in `build/xnu-work/xnu`. They're APSL-2.0 like the rest of XNU.

| Patch | Why |
|---|---|
| 0001-arm64-bti-safe-chkstk_darwin | The public toolchain's `__chkstk_darwin` has no BTI landing pad. It panics on BTI-enforcing SoCs before the console comes up. |
| 0002-newvers-kernel-builder-override | `KERNEL_BUILDER` env sets the banner's builder (reproducible builds; no personal username). |

Build: `tools/build-kernel.sh [--install]`. Run `--install` to make the result
darwin-vm's boot kernel collection.
