# Bare metal: running Finch on the M4

This is Tier 3 in `docs/HARDWARE.md`. It is the setup for booting Finch on the real
MacBook Pro (Mac16,1, M4). The rule throughout: **Finch gets its own macOS install,
with its own boot policy. Your main macOS ("Macintosh HD") stays on Full Security and
SIP, and nothing here changes its boot policy.** On Apple Silicon, security settings are
per installed OS, and every recoveryOS tool below asks which OS it's for. The answer is
always the Finch volume.

There are two parts:

1. **One-time setup (you).** Make a place for Finch, install a donor copy of macOS
   there, and lower security for that install only. About an hour, mostly waiting.
2. **Each boot test (you, from my instructions).** Install a kernel collection I've
   built onto the Finch volume and reboot into it. About five minutes.

Nothing here is needed until Finch reaches its bare-metal milestones. The first is
booting Finch's kernel with the donor macOS userland (Phase 0 on metal). After that
comes Finch's own userland (Phase 1 on metal). Do the one-time setup whenever it suits
you.

---

## Before you start

- [ ] **Back up.** Make a current Time Machine backup of the Mac. Repartitioning the
      internal disk (Option B) is routine, but don't do it without a backup.
- [ ] **Power.** Keep the charger connected for the whole session.
- [ ] **Know your password.** recoveryOS asks for an administrator password of an
      account on the OS being changed, and for your FileVault password.
- [ ] **Know how to reach Startup Options.** Shut down. Then press and hold the power
      button until "Loading startup options" appears. From there you pick an OS to boot,
      or **Options** for recoveryOS.
- [ ] **Know the fallback.** Choosing Macintosh HD in Startup Options always boots your
      normal macOS, whatever state the Finch volume is in. The worst case is that both
      macOS and recoveryOS become unbootable. That needs a DFU revive from a second Mac
      (or an Apple Store). Nothing in this procedure touches iBoot, the system
      recoveryOS or your main OS, so that outcome is very unlikely.

## Part 1: one-time setup

### 1. Choose where Finch lives

**Option A (recommended): an external SSD.** This needs no change to the internal disk.
Apple Silicon Macs boot macOS from external drives, each with its own boot policy.
- A USB-C/Thunderbolt SSD of 64 GB or more. It will be erased.
- In Disk Utility: View → Show All Devices, select the **external** device (not a
  volume on it), then Erase → Name `Finch`, Format `APFS`, Scheme `GUID Partition Map`.

**Option B: a new container on the internal SSD** (Asahi Linux uses this arrangement).
You need at least 60 GB free; at last check you had about 172 GB.
- In Terminal, find the main APFS container: `diskutil list internal` (usually
  `disk0s2`, the large `Apple_APFS` partition).
- Note its current size (`diskutil info disk0s2 | grep "Disk Size"`). Shrink it by
  60 GB and create the Finch container in the freed space. For example, with a 494 GB
  container:
  ```sh
  diskutil apfs resizeContainer disk0s2 434g APFS Finch 0
  ```
  The first size is the main container's new size. The trailing `0` gives the new
  `Finch` container all the space left over. Check the identifier and sizes against
  `diskutil list` before running this. It works while macOS is running, with no data
  loss.
- Check: `diskutil list internal` shows a new APFS container holding a volume named
  `Finch`, and Macintosh HD is unchanged apart from its size.

### 2. Install the donor macOS onto the Finch volume

Finch's kernel is built from `xnu-12377.101.15`, so the donor must be **macOS 26.4.1
(25E253)**, the same build as your main macOS. Finch loads Apple's drivers from this
install at boot rather than carrying them in its repository.

```sh
softwareupdate --list-full-installers            # is 26.4.1 offered?
softwareupdate --fetch-full-installer --full-installer-version 26.4.1
```

Open **/Applications/Install macOS ….app**. When it asks for a disk, choose
**Show All Disks → Finch**. Don't choose Macintosh HD. The Mac restarts a few times.

If 26.4.1 is no longer offered, stop and tell me which build is. I'll move the kernel
to the matching XNU tag before you install anything.

### 3. First boot of the Finch install

When setup finishes, the Mac boots into the new install. Walk through Setup Assistant:
- Create a local administrator account (for example, `finch`). Skip Apple Account
  sign-in, iCloud and Find My. They aren't needed, and Find My adds activation lock
  to the volume.
- Turn **off** FileVault for this install, if asked. That makes the recoveryOS steps
  simpler.
- Shut down.

### 4. Lower security on the Finch install only

1. Hold the power button → **Options** → Continue, and log in to recoveryOS.
2. Menu bar → **Utilities → Startup Security Utility**.
3. **Select the Finch volume** and click Security Policy… → choose **Reduced Security**.
   Tick **"Allow user management of kernel extensions from identified developers."**
   Authenticate as the Finch admin user. Leave Macintosh HD alone: it should still show
   Full Security.
4. Menu bar → **Utilities → Terminal**, then:
   ```sh
   csrutil disable
   ```
   With more than one OS installed, `csrutil` asks which volume to apply to. **Pick
   Finch.** This puts the Finch install into Permissive Security, which custom kernel
   collections and boot-args need.
5. Check:
   ```sh
   csrutil status                                # asks for a volume; pick Finch → disabled
   bputil -d                                     # pick Finch; shows the policy
   ```
   Then run `csrutil status` again, pick **Macintosh HD**, and confirm it still reports
   **enabled**.
6. Restart. Hold the power button and pick **Finch**. It should boot to the desktop
   as before, now with lowered security.

### 5. Tell me it's ready

Send me:
- Which option you used (A or B).
- The output of `sw_vers` and `uname -v` from the Finch install.
- `diskutil info /Volumes/Finch | grep -E "Volume UUID|Volume Group|APFS Container"`
  (run from your main macOS).

That's all of Part 1.

---

## Part 2: each boot test

I'll build a kernel collection on your main macOS (`build/metal/`) and give you the
exact commands for each test. They always have this shape.

**On the Finch install** (booted normally, in Terminal):
```sh
# Build a boot kernel collection from Finch's kernel plus this install's own kexts.
sudo kmutil create -a arm64e -n boot -V release \
    -k /path/from/me/kernel.release.t8132 \
    -B /Library/KernelCollections/finch.kc
```
(The exact flags, such as which kexts to include, will come with each test.)

**In recoveryOS** (hold power → Options → Utilities → Terminal):
```sh
# Install it as the boot kernel collection of the Finch volume only.
kmutil configure-boot -c "/Volumes/Finch/Library/KernelCollections/finch.kc" -v "/Volumes/Finch"
```
Always name the Finch volume with `-v`. Leave any command I send unchanged if it
doesn't do this, and ask me instead. Then restart, holding the power button, and pick
**Finch**.

What to report back:
- Whether it reached the login window or desktop, or a panic. A panic reboots the Mac
  and macOS shows a report after the next boot: copy it from Console → Crash Reports, or
  `/Library/Logs/DiagnosticReports/*.panic`.
- Anything I ask for from `sudo dmesg`.

**Going back to Apple's kernel** (any time, and after every session):
- In recoveryOS: Startup Security Utility → Finch → **Full Security**. Raising the
  policy discards the custom kernel collection, so the Finch volume boots Apple's own
  kernel again. Before the next test, repeat Part 1 step 4.
- Macintosh HD is unaffected throughout and boots normally from Startup Options.

### Later: Finch's own userland on metal

When Finch's userland is ready for metal (after the Phase 1 exit), the same Finch
volume is used. I'll give you a script that installs the Finch root alongside the donor
system, and a boot-args change (`nvram` on the Finch install, allowed under Permissive
Security) that starts Finch's `launchd` replacement. The donor macOS stays installed as
the fallback until Finch no longer needs Apple's drivers.

---

## Ground rules (for both of us)

- Main macOS: Full Security, SIP on, boot policy never touched. Every recoveryOS prompt
  in this document targets **Finch**.
- Keep Apple's SMC, PMGR and battery drivers on metal until Finch's replacements have
  been proven against them. Power, charging and thermal control are the only areas
  where a bad driver write could plausibly damage hardware.
- Nothing from your machine goes into the repository: no kernel collections, kexts,
  logs with serial numbers, or personal paths. Panic logs you send me are for
  debugging only.
