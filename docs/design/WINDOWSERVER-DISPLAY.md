# Window server: display and input in Tier 2

Finch writes its own window server and compositor, as Apple's WindowServer, SkyLight
and CoreDisplay are closed. This note covers how a Finch process in the Tier 2 guest
(`docs/design/TIER2-VZ.md`: macOS 26.6.2 25G83 under Virtualization.framework, on its
own kernel with Apple's kexts) can put pixels on the VM's display and receive keyboard
and trackpad input without any closed framework. Researched 2026-10-08.

Short answer: the guest's display is an IOMobileFramebuffer, the same kernel interface
as the M4's DCP display, and an unprivileged process can open it and submit swaps. But
while Apple's WindowServer runs, those swaps never reach the screen. Input in the guest
only exists inside WindowServer's closed HID event system. So Phase 2 starts with a
host-side viewer that Finch's compositor streams frames to, with input sent back the same
way. The direct IOMobileFramebuffer path is kept as the second backend, because it is
the one that carries over to bare metal. It needs root in the guest to test.

## What the guest has (verified)

Commands run in the guest as `developer` over `tools/vz/ssh`. SIP is on and sudo needs a
password, which Finch's tooling doesn't have, so everything below ran unprivileged.

Display (`ioreg -l -w0 -r -c AppleParavirtGPU`):

```
AppleARMIODevice "paravirtualizedgraphics,gpu"
+-o AppleParavirtGPU                    (com.apple.driver.AppleParavirtGPUIOGPUFamily, IOAccelerator)
  +-o AppleParavirtDisplay              (an IOMobileFramebuffer: 2560x1600, CursorPlane = 1,
  | |                                    ColorElements 8-bit and 10-bit, external = Yes)
  | +-o IOMobileFramebufferUserClient   x2, IOUserClientCreator "pid 194, WindowServer"
  +-o AppleParavirtDeviceUserClient     Metal clients: WindowServer, loginwindow, ...
IOSurfaceParavirtMapperDevice > IOSurfaceParavirtMapperService
```

- There is no IOFramebuffer anywhere in the registry (`grep "<class IOFramebuffer"` on
  `ioreg -l -w0` finds nothing). IOGraphicsLib (open, `IOKitUser/graphics.subproj`) and
  its IOFramebuffer shared-memory path don't apply to Apple Silicon guests.
- Loaded kexts (`kmutil showloaded`): IOMobileGraphicsFamily 343.0.0,
  AppleParavirtGPUIOGPUFamily 15.0.0, IOSurface 393.5.8, AppleParavirtIOSurface 15.0.0,
  IOGPUFamily 130.16.4. All closed, all borrowed until Phase 3 like every other kext.
- The host M4 (`ioreg -p IOService` on the host, read-only) has the same user-client
  class, `IOMobileFramebufferUserClient`, under `IOMobileFramebufferShim` (DCP).

Input (`ioreg -l -w0 -r -c AppleVirtualPlatformHIDBridge`):

```
pci106b,1a04 > AppleVirtIOPCITransport
+-o AppleVirtualPlatformHIDBridge       (com.apple.driver.AppleVirtualPlatform)
  +-o AppleVirtualPlatformHIDInterface  "Virtual Keyboard" (page 1, usage 6)
  | +-o ...HIDInterfaceUserClient       pid 341 AppleVirtualPlatformHIDBridge,
  |                                     IOUserClientEntitlements =
  |                                     com.apple.Virtualization.AppleVirtualPlatformHIDInterfaceUserClient
  +-o AppleVirtualPlatformHIDInterface  "Virtual Trackpad" (page 1, usage 2 and 1)
    +-o ...HIDInterfaceUserClient       same daemon, same entitlement
```

- `/usr/libexec/AppleVirtualPlatformHIDBridge` (launchd job
  `com.apple.Virtualization.AppleVirtualPlatformHIDBridge`, user `_avphidbridge`)
  maps the interface's memory (`IOConnectMapMemory64`, `IOConnectCallStructMethod`)
  and re-injects each event as an `HIDVirtualEventService` (HID.framework), i.e. as a
  virtual service in the user-space IOHIDEventSystem (`otool -L`, `nm -u` on a copy
  of the binary).
- On macOS that event system runs inside WindowServer: its launchd plist owns the
  Mach service `com.apple.iohideventsystem`, and the kernel `IOHIDEventServiceUserClient`s
  (buttons) are opened by "pid 194, WindowServer". `hidd` is limited to DarwinOS
  (`_LimitLoadFromVariant = IsDarwinOS`) and doesn't run.
- So the virtual keyboard and trackpad are not kernel HID devices: `IOHIDManager`
  (open, IOKitUser) sees 0 devices.

## Experiments

Probes under `build/wsprobe/` (not in the repo), built on the host and run in the guest
from the virtiofs share (`~/finch/wsprobe/...`). Note: virtiofs caches a binary by path,
so a rebuilt binary needs a new path to be seen.

| Probe | Result |
|---|---|
| `IOServiceOpen(AppleParavirtDisplay, type 0..3)`, unprivileged | all `kIOReturnSuccess` |
| `IOServiceOpen(IOSurfaceRoot, 0)` | success |
| `IOServiceOpen(AppleParavirtGPU, 0..3)` | `0xe00002c7` (unsupported type) |
| `IOServiceOpen(IOHIDSystem, 0)` / `(.., 1)` | `0xe00002bd` not privileged / success (param client) |
| `IOServiceOpen(IOHIDEventService, 'esuc')`, `IOServiceOpen(AppleVirtualPlatformHIDInterface, 0..2)` | refused (`0xe00002c2`, `0xe00002c7`) |
| Same, ad-hoc signed with `com.apple.hid.system.user-access-service` or the Virtualization entitlement | killed at launch by AMFI (exit 137): both are restricted |
| `IOHIDManagerCopyDevices` | 0 devices |
| Present a test pattern through the IOMobileFramebuffer user client while WindowServer runs (below) | every call succeeds, nothing appears on screen, swap-wait times out |
| 2560x1600 BGRA frames over TCP, guest to host (NAT, `192.168.64.1`) | 958 MB/s, 17.1 ms per full frame (58 fps) |

The presentation probe drove Apple's IOMobileFramebuffer and IOSurface libraries in a
test process, with an interposed tracer logging the user-client calls they make, so
that Finch learns the kernel interface without using the libraries. This is the same
method as `tools/xpc-capture`. Recorded (macOS 26.6.2):

- IOMobileFramebufferUserClient (type 0):
  - selector 8, no input, 2 scalars out: display size (`0xa00, 0x640`).
  - selector 4, 1 scalar out: swap begin, returns the swap id.
  - selector 5, 1416-byte struct in: swap submit. The swap id is at +0x98, the
    layer-0 IOSurface id at +0x9c, and the source and destination sizes as integers at
    +0xb4/+0xb8 and +0x114/+0x118.
  - selector 6, scalars {swap id, timeout in ms, 0}: swap wait.
- IOSurfaceRootUserClient (type 0): selector 13 (40 bytes out, root limits) then
  selector 0 (create). The properties go in as a 264-byte binary-serialized OSDictionary
  (magic `0xd3`), and 3176 bytes come out with the new surface id at +0x18.

Swap begin and submit return success on both layer 0 and layer 1. The frame never
shows, though: host screenshots of the VM window (`screencapture -l<window id>`) keep
showing the login window, and swap-wait returns `kIOReturnTimeout`. The kernel accepts
swaps from a second client but only scans out the owning client's. That is inferred: the
obvious alternative, that the display was asleep, was ruled out by waking it with
`caffeinate -u` first. (The login window turns the display off after a short idle, so
it's black in a screenshot until there's user activity.) WindowServer kept running
throughout, and nothing in the guest was changed.

## Options

### A. Host viewer: stream frames out, input back (recommended first)

Finch's compositor renders into its own CPU framebuffer (software rendering, as the
roadmap says) and sends damaged rectangles to a viewer on the host (a new `tools/vz`
window, AppKit on the host like `finch-vz` itself). The viewer sends keyboard, pointer
and trackpad events back. Transport: TCP over the existing NAT now, virtio-vsock once
`finch-vz` adds a `VZVirtioSocketDeviceConfiguration`. XNU has the vsock domain
(`bsd/kern/vsock_domain.c`, open), and the guest has `net.vsock.*` sysctls.

- Works today: no root, no SIP change, no reverse engineering, and Apple's WindowServer
  can keep running underneath (the guest's own display just shows the login window).
- Latency: one full 2560x1600 frame is 17 ms over TCP. Damage-only updates (cursor,
  typing, a window moving) are far smaller, and lz4 or plain RLE would cut them further.
  It's good enough for apps, but not a fair measure of frame pacing.
- Effort: small. A framebuffer wire format, a viewer window, and an input event format
  that maps NSEvent to Finch's own event types.
- Fidelity: the window server, compositor, event routing and CoreGraphics' window side
  are all real. The display and HID drivers aren't exercised, and the HID event system
  is skipped.
- Bare metal: the transport goes away. The compositor's output and input are backends
  behind one interface, so this backend becomes a test harness (headless CI and
  screenshots).

### B. Direct IOMobileFramebuffer in the guest (the metal path)

Finch's own IOMobileFramebuffer and IOSurface clients (over open IOKitUser, with the
selectors above) present the compositor's surfaces directly.

- Needs WindowServer stopped, which needs root in the guest. Untested, but presumably:
  `sudo launchctl bootout system/com.apple.WindowServer`, or for a persistent change
  `sudo launchctl disable system/com.apple.WindowServer` and reboot. Undo it with
  `sudo launchctl enable system/com.apple.WindowServer` over SSH, which doesn't depend
  on WindowServer. Whether loginwindow or launchd restarts it, and whether SIP allows
  disabling the job, is still to be checked. Stopping WindowServer also stops the HID
  event system and the guest's Metal clients.
- Input then has no source, because Apple's bridge daemon feeds WindowServer's event
  system. Two ways to get it back:
  1. Finch's own IOHIDEventSystem server, registered as `com.apple.iohideventsystem`,
     receiving the bridge daemon's virtual services. Finch needs this server anyway: the
     client side is open (`IOHIDFamily/HID/HIDVirtualEventService.m`), but the event
     system itself is closed (Apple publishes `IOHIDEventSystem*.c` and the MIG `.defs`
     in IOKitUser as empty files), so its MIG protocol has to be recorded, the way XPC was.
  2. Replace the bridge daemon and read `AppleVirtualPlatformHIDInterfaceUserClient`
     directly. That needs the restricted Virtualization entitlement, so AMFI has to be
     relaxed in the guest (SIP off plus a boot-arg, set from the guest's Recovery).
     This changes the guest's security policy, not its boot chain, and it's
     VZ-specific work that doesn't carry over.
- Latency: native (a zero-copy swap of the surface).
- Effort: medium. Record the rest of the swap-submit struct (layer flags, transforms,
  the cursor plane), vsync and swap-complete notifications (`IOConnectSetNotificationPort`),
  and the IOSurface lock and wiring calls. Then build the HID event-system server.
- Fidelity: high. It's the same user-client class the M4's DCP driver exposes
  (`IOMobileFramebufferShim` on the host), so the Finch client code runs unchanged on
  metal while Apple's DCP kexts are borrowed. In Phase 3, Finch's own DCP driver can
  keep that interface. Asahi's documentation of DCP's firmware RPC shows the same
  IOMobileFramebufferAP methods underneath (`swap_start`, `swap_submit_dcp`).

### Not viable

- IOFramebuffer and IOGraphicsLib: there's no IOFramebuffer on Apple Silicon.
- IOHIDManager or IOHIDDevice (open) for VZ input: there are no kernel HID devices.
- Reading Apple's event system from the guest: the client library and protocol are
  closed, and the monitor entitlements (`com.apple.private.hid.client.event-monitor`)
  are restricted anyway.
- Host-side VZ capture: `VZVirtualMachineView` shows the guest display but has no
  public API for reading frames, and Finch doesn't use private VZ API.
- Shared-memory framebuffer over virtiofs: VZ's virtiofs has no DAX mapping, so it
  would be a file copy and slower than a socket.

## Recommendation

1. Build the compositor around an output and input backend interface from the start
   (something like a `finch-ws` backend: present a damaged surface; deliver input events).
2. First backend: A, the host viewer, over TCP and then vsock. That unblocks the window
   server, CoreGraphics' window side and AppKit now.
3. In parallel, once the guest has root: test B's open question (the display scans out
   Finch's swaps once WindowServer is stopped), then write Finch's IOMobileFramebuffer
   and IOSurface clients, and the HID event-system server that Phase 2 needs for app
   compatibility anyway. B is what goes to metal.
4. Bare metal (Tier 3): B on the borrowed DCP kexts, with input from the kernel
   `IOHIDEventService`s (keyboard and trackpad over the M4's SPI/MTP transport)
   through `IOHIDEventServiceUserClient`. Its kernel side is open
   (`IOHIDFamily/IOHIDEventServiceUserClient.cpp`, type `'esuc'`), and it requires
   `com.apple.hid.system.user-access-service`. Phase 3 replaces the DCP and HID kexts.

## Open questions

- With WindowServer stopped, does `AppleParavirtDisplay` scan out a second client's
  swaps, or does it need a claim or power call first? This needs root in the guest.
  The user has to provide sudo, for example a NOPASSWD sudoers entry for `developer`.
- Can `com.apple.WindowServer` be disabled with SIP on? Does loginwindow cope?
- The rest of the IOMobileFramebuffer swap struct, plus the vsync and swap-done
  notifications and the cursor plane (`CursorPlane = 1`).
- Do CPU-allocated IOSurfaces reach the host through `IOSurfaceParavirtMapperService`
  without Metal?
- The `com.apple.iohideventsystem` MIG protocol: virtual-service registration and
  event dispatch.
- Entitlements on Finch's own OS: Finch's daemons need
  `com.apple.hid.system.user-access-service` and similar entitlements. On metal, that
  depends on who enforces AMFI policy there.
