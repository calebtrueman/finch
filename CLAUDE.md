# Finch: notes for Claude

Finch is an open-source OS for Apple Silicon built on Darwin/XNU and aiming at macOS
binary compatibility. Read `README.md` and `docs/` before making structural decisions.

Hard rules:
- Never commit Apple proprietary binaries (kexts, frameworks, firmware, KDK contents).
  Bootstrap loads them from the user's macOS install at runtime only.
- Never copy GPL code (Asahi Linux kernel drivers, Darling) into Finch kexts or APSL/MIT
  code. Follow the clean-room rule in `docs/LICENSING.md`.
- Pin Apple open-source imports to exact tags (e.g., `xnu-12377.101.15`).
- The dev machine (M4) is the build host. Don't change its boot security settings.
  Experimental boots go on a separate test Mac.
