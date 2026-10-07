// SPDX-License-Identifier: MIT OR Apache-2.0
//
// finch-vz: Tier 2 test VM (docs/HARDWARE.md, docs/design/TIER2-VZ.md).
// A macOS guest in Virtualization.framework, with a display, into which
// Finch's VMAPPLE kernel collection is installed.
//
//   finch-vz fetch                download the latest restore image Apple
//                                 supports for VMs (build/vz/restore.ipsw)
//   finch-vz install              create the VM and install macOS into it
//   finch-vz run [--recovery] [--headless]
//                                 boot it in a window (--recovery: into
//                                 macOS Recovery, for kmutil configure-boot;
//                                 --headless: no window, e.g. over SSH)
//
// If build/vz/AVPBooter.bin exists, the VM boots that ROM instead of the
// host's (Virtualization's private -[VZMacOSBootLoader _setROMURL:]), so a
// patched stage 0 never means modifying the host's Virtualization.framework.
//
// The VM lives in build/vz/. Finch's build/ tree is shared into the guest,
// read-only, as the virtiofs tag "finch" (mount_virtiofs finch /Volumes/finch).

import AppKit
import Foundation
import Virtualization

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let vmDir = root.appendingPathComponent("build/vz", isDirectory: true)
let restoreImage = vmDir.appendingPathComponent("restore.ipsw")
let diskImage = vmDir.appendingPathComponent("disk.img")
let auxStorage = vmDir.appendingPathComponent("aux.img")
let hardwareModelFile = vmDir.appendingPathComponent("hardware-model")
let machineIDFile = vmDir.appendingPathComponent("machine-id")
let customROM = vmDir.appendingPathComponent("AVPBooter.bin")
let diskSize: UInt64 = 96 << 30   // sparse: grows with use

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("finch-vz: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func progress(_ label: String, _ fraction: Double) {
    let line = String(format: "\r%@ %5.1f%%", label, fraction * 100)
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// MARK: - fetch

final class Downloader: NSObject, URLSessionDownloadDelegate {
    let done = DispatchSemaphore(value: 0)
    var error: Error?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress("downloading", Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: restoreImage)
            try FileManager.default.moveItem(at: location, to: restoreImage)
        } catch {
            self.error = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { self.error = error }
        done.signal()
    }
}

func fetch() {
    try? FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
    var found: VZMacOSRestoreImage?
    let lookup = DispatchSemaphore(value: 0)
    VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let image): found = image
        case .failure(let error): die("restore image lookup failed: \(error.localizedDescription)")
        }
        lookup.signal()
    }
    lookup.wait()
    guard let image = found else { die("no supported restore image") }
    print("macOS \(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion) (\(image.buildVersion)): \(image.url)")
    let downloader = Downloader()
    let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
    session.downloadTask(with: image.url).resume()
    downloader.done.wait()
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    if let error = downloader.error { die("download failed: \(error.localizedDescription)") }
    print("saved \(restoreImage.path)")
}

// MARK: - configuration

func platform(creating: VZMacOSRestoreImage? = nil) -> VZMacPlatformConfiguration {
    let platform = VZMacPlatformConfiguration()
    if let image = creating {
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            die("this Mac can't run that restore image")
        }
        platform.hardwareModel = requirements.hardwareModel
        platform.machineIdentifier = VZMacMachineIdentifier()
        do {
            platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxStorage, hardwareModel: requirements.hardwareModel,
                options: [.allowOverwrite])
            try requirements.hardwareModel.dataRepresentation.write(to: hardwareModelFile)
            try platform.machineIdentifier.dataRepresentation.write(to: machineIDFile)
        } catch {
            die("creating platform: \(error.localizedDescription)")
        }
    } else {
        guard let modelData = try? Data(contentsOf: hardwareModelFile),
              let model = VZMacHardwareModel(dataRepresentation: modelData),
              let idData = try? Data(contentsOf: machineIDFile),
              let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            die("no VM in \(vmDir.path) (run: finch-vz install)")
        }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxStorage)
    }
    return platform
}

func configuration(_ platform: VZMacPlatformConfiguration) -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()
    config.platform = platform
    let bootLoader = VZMacOSBootLoader()
    if FileManager.default.fileExists(atPath: customROM.path) {
        let setter = NSSelectorFromString("_setROMURL:")
        guard bootLoader.responds(to: setter) else { die("this Virtualization has no _setROMURL:") }
        bootLoader.perform(setter, with: customROM)
        FileHandle.standardError.write("finch-vz: booting ROM \(customROM.path)\n".data(using: .utf8)!)
    }
    config.bootLoader = bootLoader
    config.cpuCount = max(2, min(6, ProcessInfo.processInfo.processorCount - 2))
    config.memorySize = 8 << 30

    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600,
                                                           pixelsPerInch: 220)]
    config.graphicsDevices = [graphics]

    do {
        let disk = try VZDiskImageStorageDeviceAttachment(url: diskImage, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    } catch {
        die("disk: \(error.localizedDescription)")
    }

    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [network]

    config.keyboards = [VZMacKeyboardConfiguration()]
    config.pointingDevices = [VZMacTrackpadConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    // Finch's build tree, read-only, for installing kernel collections from the guest.
    let share = VZVirtioFileSystemDeviceConfiguration(tag: "finch")
    share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(
        url: root.appendingPathComponent("build"), readOnly: true))
    config.directorySharingDevices = [share]

    do {
        try config.validate()
    } catch {
        die("configuration: \(error.localizedDescription)")
    }
    return config
}

// MARK: - install

func install() {
    guard FileManager.default.fileExists(atPath: restoreImage.path) else {
        die("no restore image (run: finch-vz fetch)")
    }
    let loaded = DispatchSemaphore(value: 0)
    var image: VZMacOSRestoreImage?
    VZMacOSRestoreImage.load(from: restoreImage) { result in
        switch result {
        case .success(let i): image = i
        case .failure(let error): die("restore image: \(error.localizedDescription)")
        }
        loaded.signal()
    }
    loaded.wait()

    FileManager.default.createFile(atPath: diskImage.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: diskImage) else { die("can't create disk") }
    do {
        try handle.truncate(atOffset: diskSize)
        try handle.close()
    } catch {
        die("disk: \(error.localizedDescription)")
    }

    let config = configuration(platform(creating: image!))
    DispatchQueue.main.async {
        let vm = VZVirtualMachine(configuration: config)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            progress("installing", p.fractionCompleted)
        }
        installer.install { result in
            observation.invalidate()
            FileHandle.standardError.write("\n".data(using: .utf8)!)
            switch result {
            case .success:
                print("installed; next: finch-vz run (complete Setup Assistant, enable Remote Login)")
                exit(0)
            case .failure(let error):
                die("install failed: \(error.localizedDescription)")
            }
        }
    }
    dispatchMain()
}

// MARK: - run

final class Runner: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    let recovery: Bool, headless: Bool
    var vm: VZVirtualMachine!
    var window: NSWindow!

    init(recovery: Bool, headless: Bool) {
        self.recovery = recovery
        self.headless = headless
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        vm = VZVirtualMachine(configuration: configuration(platform()))
        vm.delegate = self
        if headless {
            start()
            return
        }
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = recovery ? "Finch VM (Recovery)" : "Finch VM"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        start()
    }

    func start() {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = recovery
        vm.start(options: options) { error in
            if let error { die("start failed: \(error.localizedDescription)") }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { exit(0) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        die("stopped: \(error.localizedDescription)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !headless }
}

func run(recovery: Bool, headless: Bool) {
    let app = NSApplication.shared
    let runner = Runner(recovery: recovery, headless: headless)
    app.setActivationPolicy(headless ? .prohibited : .regular)
    app.delegate = runner
    app.run()
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "fetch": fetch()
case "install": install()
case "run": run(recovery: args.contains("--recovery"), headless: args.contains("--headless"))
default:
    FileHandle.standardError.write("usage: finch-vz fetch | install | run [--recovery] [--headless]\n".data(using: .utf8)!)
    exit(2)
}
