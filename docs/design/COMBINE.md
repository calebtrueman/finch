# Combine

Apple's Combine is closed source. Finch's `Combine.framework` is open code built to look
the same to apps: they load `/System/Library/Frameworks/Combine.framework` and look up Swift
symbols named `$s7Combine…`, so the open code is compiled as module `Combine`, with library
evolution, under that install name.

## Sources

- **OpenCombine** 0.14.0 (MIT), an open reimplementation of Combine's API. Its core module
  only: Apple's Combine imports just Darwin and Swift, and its Dispatch, RunLoop and
  Foundation integrations live in Foundation's overlay. `userland/Combine/adapt.py` adapts
  a copy of its sources:
  - names qualified with OpenCombine's module become Combine's;
  - `Result.Publisher` and `Optional.Publisher` replace OpenCombine's
    `Result.OCombine.Publisher` and `Optional.OCombine.Publisher`;
  - the parts OpenCombine leaves out where Apple's Combine exists are kept;
  - `@inlinable` becomes `@usableFromInline` on internal code (its symbols are exported, as
    Apple's are) and is dropped on public code;
  - the types whose layout is ABI are frozen as Apple's are: `AnyPublisher`,
    `AnySubscriber`, `Subscribers.Demand` and `Subscribers.Completion` (`@frozen`), and the
    boxes behind the first two (`@_fixed_layout`).
- **Finch's own** (`userland/Combine/Finch/`): what OpenCombine lacks. `Merge` (2 to 8),
  `MergeMany`, and `CombineLatest` (2 to 4) are declared by `gen.py` exactly as Apple's
  public interface declares them, and run on one fan-in subscription (`FanIn.swift`).
  Collecting by time (`CollectByTime`, `TimeGroupingStrategy`) is written by hand.

Apple's SDK `.swiftinterface` is used only as the API reference, as a header is. Its
inlinable bodies are Apple's code and are not copied.

## Status

- 2026-10-09: 1,977 of Apple's 2,023 Swift symbols (`tools/check-swift-parity.sh`). Every
  Combine symbol the 29 system apps that link Combine import is there. The rest are mostly
  `Publishers.Label`, a few `Zip` equality conformances and the property-wrapper hooks
  SwiftUI uses (`_ObservableObjectProperty`). `finch-combine-test` matches Apple's output
  on the host and in the VM. It covers:
  - the publishers, operators and subjects;
  - live `merge` and `combineLatest`, with demand;
  - `sink`, `assign` and cancellation;
  - `@Published` and `ObservableObject`;
  - `debounce` and collecting by time on a virtual-time scheduler.
