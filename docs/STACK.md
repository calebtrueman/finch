# Finch software stack

What runs on Finch today and where each piece comes from, bottom to top.
`docs/ARCHITECTURE.md` explains the layers. `docs/ROADMAP.md` covers what comes next.
These diagrams are updated in every commit that changes the stack, and
`tools/render-stack.sh` checks that they render.

**As of 2026-10-08:** nothing Finch builds links a closed library
(`tools/check-closed.py`). Finch's own Foundation covers about 130 of Apple's
classes, on a CoreFoundation that dispatches to Objective-C objects as Apple's
does (`docs/design/FOUNDATION.md`); its NSXMLParser runs on Apple's libxml2,
built by Finch. Finch's CoreGraphics has begun, over Skia
(`docs/design/COREGRAPHICS.md`): bitmap contexts draw paths, images,
clips, shadows and transparency layers as Apple's do. Finch's ImageIO reads
PNG, JPEG, GIF, BMP, ICO and WebP and writes PNG and JPEG over the open
codecs Skia builds, returning the CGImages and properties Apple's does. CoreText lays out text with HarfBuzz, FreeType and ICU, as Apple's does.
Finch's window server composites windows that apps draw with CoreGraphics
into shared memory, and routes input to them (`docs/design/WINDOWSERVER.md`).

```mermaid
block-beta
    columns 1
    block:L7
        columns 4
        t7["Apps and desktop"]
        apps["Unmodified Mac apps"]
        desktop["finch-windowserver<br/>windows over shared memory,<br/>Skia compositor, cursor,<br/>input routing (headless, viewer)"]
        shell["Dock / Finder-alikes"]
    end
    block:L6
        columns 4
        t6["App frameworks"]
        appkit["AppKit"]
        cg["CoreGraphics<br/>bitmap contexts, paths, images,<br/>gradients, patterns, fonts, text,<br/>shadows (over Skia, skcms);<br/>window server client, displays"]
        imageio["ImageIO<br/>image sources, thumbnails,<br/>destinations, property keys<br/>(libpng, libjpeg-turbo, libwebp,<br/>wuffs, via Skia)"]
        space6[" "]
        ctio["CoreText<br/>fonts, shaping, lines, frames<br/>(HarfBuzz, FreeType, ICU)"]
        later["QuartzCore, Metal, SwiftUI, AV"]
        space6b[" "]
    end
    block:L5
        columns 4
        t5["Foundation layer"]
        foundation["Foundation<br/>strings, numbers, decimals, threads,<br/>files, bundles, formatters, queues,<br/>KVC/KVO, JSON, archiving, regexes,<br/>attributed strings, map/hash tables,<br/>undo, proxies, transforms,<br/>file handles, pipes, tasks,<br/>predicates, progress, file wrappers,<br/>units and measurements, XML parsing"]
        cf["CoreFoundation<br/>swift-corelibs CF + Finch ObjC:<br/>toll-free dispatch, collections,<br/>ordered sets, NSCache, NSData, NSDate,<br/>NSURL, locales, calendars, defaults,<br/>run loops, attributed strings,<br/>streams, Mach ports"]
        od["OpenDirectory<br/>CFOpenDirectory"]
        space5[" "]
        icu["libicucore<br/>ICU-76142.4.7"]
        objc["libobjc (objc4)"]
        swift["libswiftCore 6.3.1"]
        space5b[" "]
        iokit["IOKit.framework<br/>(IOKitUser)"]
        gcore["GCoreFramework<br/>(gcore, on Finch Foundation)"]
        space5c[" "]
    end
    block:L4
        columns 4
        t4["Libraries"]
        comp["libcompression<br/>LZFSE, LZ4, Brotli, zlib, LZMA"]
        codecs["lzfse, lz4, brotli,<br/>liblzma, libxo, libsbuf"]
        osslibs["zlib, bzip2, libedit, libresolv,<br/>libiconv, ncurses, OpenBSM,<br/>libxml2"]
        space4[" "]
        pam["OpenPAM + pam_modules"]
        pamunix["pam_unix, Finch pam.d"]
        ess["libEndpointSecuritySystem"]
        space4b[" "]
        tz["tzdata 2026c (IANA)"]
        skia["Skia m155 + FreeType, HarfBuzz,<br/>libpng, libjpeg-turbo, libwebp, wuffs<br/>(static, for CoreGraphics<br/>and ImageIO)"]
        space4d[" "]
    end
    block:L3
        columns 4
        t3["libSystem"]
        libc["Libc, libmalloc, libpthread,<br/>libplatform, libdispatch, Libinfo,<br/>Libnotify, asl, copyfile"]
        kernlib["libsystem_kernel<br/>(libsyscall)"]
        dyld["dyld + Finch shared cache"]
        space3[" "]
        xpc["libxpc<br/>Apple's wire protocol"]
        cc["libcorecrypto<br/>over OpenSSL 3.5.9"]
        stubs["libsystem_* (sandbox, trace,<br/>featureflags, quarantine...), libm"]
        space3b[" "]
        cxx["libc++, compiler-rt<br/>(LLVM runtimes)"]
        space3c[" "]
        space3d[" "]
    end
    block:L2
        columns 4
        t2["Processes"]
        init["finch-init (PID 1)<br/>bootstrap server,<br/>system + user domains"]
        logd["finch-logd, launchctl,<br/>sh, mount_tmpfs, devtools"]
        daemons["notifyd, syslogd, aslmanager,<br/>newsyslog, dynamic_pager, atrun"]
        space2[" "]
        cmds["file/shell/text/adv/system_cmds,<br/>bash, zsh, bc, su, login"]
        space2b[" "]
        space2c[" "]
    end
    block:L1
        columns 4
        t1["Kernel"]
        xnu["XNU xnu-12377.101.15<br/>+ Finch patches"]
        kexts["Platform drivers<br/>(Finch's later)"]
        space1[" "]
    end
    block:L0
        columns 4
        t0["Machines"]
        qemu["Tier 1: QEMU darwin-vm"]
        vz["Tier 2: Virtualization.framework<br/>guest, own kernel"]
        metal["Tier 3: M4 bare metal<br/>(deferred)"]
    end

    classDef layer fill:#111827,stroke:#111827,color:#ffffff,font-weight:bold
    classDef apple fill:#dbeafe,stroke:#1d4ed8,color:#0b1b3f
    classDef finch fill:#fde68a,stroke:#b45309,color:#3b2300
    classDef upstream fill:#dcfce7,stroke:#15803d,color:#052e12
    classDef planned fill:#f3f4f6,stroke:#9ca3af,color:#6b7280,stroke-dasharray:4 3
    classDef firmware fill:#fee2e2,stroke:#b91c1c,color:#450a0a
    classDef blank fill:none,stroke:none
    class t7,t6,t5,t4,t3,t2,t1,t0 layer
    class apps,shell,appkit,later,kexts,metal planned
    class desktop,cg,imageio,ctio,cf,foundation,od,comp,pamunix,ess,xpc,cc,stubs,init,logd finch
    class icu,objc,iokit,gcore,osslibs,pam,libc,kernlib,dyld,daemons,cmds,xnu apple
    class swift,codecs,cxx,qemu,tz,skia upstream
    class vz firmware
    class space6,space6b,space5,space5b,space5c,space4,space4b,space4d,space3,space3b,space3c,space3d,space2,space2b,space2c,space1 blank
```

| Colour | Meaning |
|---|---|
| Blue | Apple's open source, built by Finch (pinned tags, `userland/projects.txt`) |
| Yellow | Written by Finch |
| Green | Third-party upstream, built by Finch |
| Red | Apple firmware or boot chain, used as shipped (never redistributed) |
| Grey, dashed | Planned |

## How the libraries link

The edges are load-time links (`otool -L`). Foundation's link is the upward
link Apple's CoreFoundation also has.

```mermaid
flowchart LR
    classDef apple fill:#dbeafe,stroke:#1d4ed8,color:#0b1b3f
    classDef finch fill:#fde68a,stroke:#b45309,color:#3b2300
    classDef upstream fill:#dcfce7,stroke:#15803d,color:#052e12
    classDef planned fill:#f3f4f6,stroke:#9ca3af,color:#6b7280,stroke-dasharray:4 3
    classDef closed fill:#ffffff,stroke:#b91c1c,color:#b91c1c,stroke-width:2px

    gcore["GCoreFramework"]:::apple
    ffound["Foundation"]:::finch
    cgfw["CoreGraphics"]:::finch
    ctfw["CoreText"]:::finch
    imageio["ImageIO"]:::finch
    skialib["Skia, FreeType<br/>(static)"]:::upstream
    cxxlib["libc++"]:::upstream
    cf["CoreFoundation"]:::finch
    iokit["IOKit"]:::apple
    od["OpenDirectory"]:::finch
    objc["libobjc"]:::apple
    swift["libswiftCore"]:::upstream
    icu["libicucore"]:::apple
    xml["libxml2"]:::apple
    comp["libcompression"]:::finch
    codecs["lzfse / lz4 / brotli<br/>(static)"]:::upstream
    lzma["liblzma"]:::upstream
    z["libz"]:::apple
    pamlib["libpam (OpenPAM)"]:::apple
    pammods["pam_unix, pam_launchd, ..."]:::finch
    su["su, login"]:::apple
    xpc["libxpc"]:::finch
    init["finch-init"]:::finch
    sys["libSystem.B"]:::apple
    kern["libsystem_kernel"]:::apple
    xnu["XNU"]:::apple

    gcore --> ffound
    gcore -.->|"linked, unused"| comp
    ffound -->|"re-exports"| cf
    cf -.->|"upward, as Apple's"| ffound
    cf --> objc --> swift
    cf --> icu
    ffound --> icu
    ffound --> xml
    xml --> icu
    xml --> z
    iokit --> cf
    cgfw --> cf
    ctfw --> cgfw
    ctfw --> cf
    ctfw --> icu
    ctfw --> skialib
    cgfw --> skialib
    cgfw --> cxxlib
    imageio --> cgfw
    imageio --> cf
    imageio --> skialib
    imageio --> cxxlib
    od --> cf
    comp --> codecs
    comp --> lzma
    comp --> z
    su --> pamlib --> pammods
    pammods --> xpc
    init --> xpc
    cf --> sys
    objc --> sys
    xpc --> sys
    sys --> kern --> xnu
```

