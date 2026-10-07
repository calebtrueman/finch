/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Exercise the C++ runtimes (libc++, libc++abi, libunwind): exceptions
 * across frames, RTTI, iostreams, threads, std::format, containers.
 * Prints "cxx: N/N passed" and exits nonzero on any failure; -v traces
 * each step to stderr.
 */

#include <atomic>
#include <csignal>
#include <dlfcn.h>
#include <mach-o/dyld_images.h>
#include <mach/mach.h>
#include <ptrauth.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <exception>
#include <format>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <typeinfo>
#include <vector>

static int passed, failed;
static bool verbose;

static void step(const char *what)
{
    if (verbose)
        std::fprintf(stderr, "cxx: %s\n", what);
}

// -v: on a crash, print the fault and a frame-pointer backtrace (the VM
// has no crash reporter).
static void print_pc(const char *tag, uint64_t pc)
{
    pc = (uint64_t)ptrauth_strip((void *)pc, ptrauth_key_return_address);
    Dl_info info{};
    if (dladdr((void *)pc, &info) && info.dli_fname)
        std::fprintf(stderr, "  %s 0x%llx %s`%s+%lld\n", tag, (unsigned long long)pc,
                     std::strrchr(info.dli_fname, '/') ? std::strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
                     info.dli_sname ? info.dli_sname : "?",
                     (long long)(pc - (uint64_t)(info.dli_saddr ? info.dli_saddr : info.dli_fbase)));
    else
        std::fprintf(stderr, "  %s 0x%llx\n", tag, (unsigned long long)pc);
}

static void on_crash(int sig, siginfo_t *si, void *ctx)
{
    auto *mc = static_cast<ucontext_t *>(ctx)->uc_mcontext;
    std::fprintf(stderr, "cxx: signal %d at address %p\n", sig, si->si_addr);
    task_dyld_info_data_t di;
    mach_msg_type_number_t n = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&di, &n) == KERN_SUCCESS)
        std::fprintf(stderr, "  dyld at %p\n",
                     ((const struct dyld_all_image_infos *)di.all_image_info_addr)->dyldImageLoadAddress);
    print_pc("pc", __darwin_arm_thread_state64_get_pc(mc->__ss));
    print_pc("lr", __darwin_arm_thread_state64_get_lr(mc->__ss));
    auto *fp = (uint64_t *)__darwin_arm_thread_state64_get_fp(mc->__ss);
    uint64_t last = 0;
    int repeats = 0;
    for (int i = 0; fp && i < 100000; i++, fp = (uint64_t *)fp[0]) {
        if (fp[1] == last) {
            repeats++;
            continue;
        }
        if (repeats)
            std::fprintf(stderr, "  ... repeated %d times\n", repeats);
        repeats = 0;
        last = fp[1];
        print_pc("fp", fp[1]);
    }
    _exit(128 + sig);
}

static void check(bool ok, const char *what)
{
    if (ok)
        passed++;
    else {
        failed++;
        std::cerr << "FAIL: " << what << '\n';
    }
}

struct Base { virtual ~Base() = default; };
struct Derived : Base { int v = 42; };

[[gnu::noinline]] static void thrower(int depth)
{
    if (depth == 0)
        throw std::runtime_error("deep");
    std::string keep = "frame";  // a destructor to run during unwinding
    thrower(depth - 1);
}

int main(int argc, char **argv)
{
    verbose = argc > 1 && std::strcmp(argv[1], "-v") == 0;
    if (verbose) {
        static char altstack[64 * 1024];
        stack_t ss{};
        ss.ss_sp = altstack;
        ss.ss_size = sizeof(altstack);
        sigaltstack(&ss, nullptr);
        struct sigaction sa{};
        sa.sa_sigaction = on_crash;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigaction(SIGSEGV, &sa, nullptr);
        sigaction(SIGBUS, &sa, nullptr);
        sigaction(SIGILL, &sa, nullptr);
    }

    // Exceptions unwinding through several frames.
    step("throw across frames");
    try {
        thrower(10);
        check(false, "throw across frames");
    } catch (const std::exception &e) {
        check(std::string(e.what()) == "deep", "throw across frames");
    }

    step("rethrow");
    // Catch by base, rethrow, catch(...).
    bool rethrown = false;
    try {
        try { throw std::out_of_range("x"); }
        catch (const std::logic_error &) { throw; }
    } catch (...) { rethrown = true; }
    check(rethrown, "rethrow");

    step("exception_ptr");
    // std::exception_ptr.
    std::exception_ptr ep;
    try { throw 7; } catch (...) { ep = std::current_exception(); }
    try { std::rethrow_exception(ep); } catch (int n) { check(n == 7, "exception_ptr"); }

    step("rtti");
    // RTTI and dynamic_cast.
    std::unique_ptr<Base> b = std::make_unique<Derived>();
    auto *d = dynamic_cast<Derived *>(b.get());
    check(d && d->v == 42, "dynamic_cast");
    Base &br = *b;
    check(typeid(br) == typeid(Derived), "typeid");
    try { (void)dynamic_cast<Derived &>(*std::make_unique<Base>()); check(false, "bad_cast"); }
    catch (const std::bad_cast &) { check(true, "bad_cast"); }

    step("iostreams");
    // iostreams and std::format.
    std::ostringstream os;
    os << 3.5 << ' ' << std::hex << 255;
    check(os.str() == "3.5 ff", "ostringstream");
    check(std::format("{:>5}|{:x}", 42, 255) == "   42|ff", "std::format");

    step("containers");
    // Containers.
    std::map<std::string, int> m{{"a", 1}, {"b", 2}};
    std::vector<int> v(1000, 1);
    check(m.at("b") == 2 && v.size() == 1000, "containers");
    try { (void)m.at("zz"); check(false, "map::at throws"); }
    catch (const std::out_of_range &) { check(true, "map::at throws"); }

    step("threads");
    // Threads, mutex, atomics, exceptions on other threads.
    std::atomic<int> sum{0};
    std::mutex mu;
    int guarded = 0;
    std::vector<std::thread> ts;
    for (int i = 0; i < 8; i++)
        ts.emplace_back([&, i] {
            try { if (i % 2) throw i; } catch (int) {}
            sum += i;
            std::lock_guard<std::mutex> g(mu);
            guarded++;
        });
    for (auto &t : ts)
        t.join();
    check(sum == 28 && guarded == 8, "threads");

    std::cout << "cxx: " << passed << "/" << passed + failed << " passed\n";
    return failed != 0;
}
