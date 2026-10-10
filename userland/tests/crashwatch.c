/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * crashwatch: report a child process's crash (its Mach exception) with a backtrace.
 *
 * The parent spawns the child with an exception port of its own (crashwatch_spawnattr);
 * a thread waits on it. When the child takes an exception (a bad access, a pointer
 * authentication failure, a trap), it prints the exception, the registers and a
 * frame-pointer backtrace, each frame as image + offset (as `atos -o IMAGE -l 0 OFFSET`
 * reads it), then lets the exception go on to kill the child as it would have. The task's
 * memory (for the backtrace past the registers) is read through its identity token, which
 * needs developer mode (as in the VM) or the rights to read the task, or by its pid, which
 * needs root, a child that allows debugging (get-task-allow, as test apps are signed) and
 * the debugger entitlement (debugger.entitlements).
 *
 * It needs no symbols in the process: in the Finch VM, where there is no crash reporter
 * yet, the report goes out over the console to be symbolized on the host.
 */
#include "crashwatch.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/*
 * The exception message: mach_exception_raise_state_identity_protected (mach_exc.defs), the
 * registers and a task identity token. Finch's own programs are platform binaries in the
 * VM, and the kernel kills one that sets an exception port whose messages carry task and
 * thread control ports (EXCEPTION_DEFAULT); identity-protected ones are allowed.
 */
#define RAISE_STATE_IDENTITY_PROTECTED 2410

#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t task_token;
    NDR_record_t ndr;
    uint64_t thread_id;
    exception_type_t exception;
    mach_msg_type_number_t code_count; /* always 2 with MACH_EXCEPTION_CODES */
    int64_t code[2];
    int flavor;
    mach_msg_type_number_t state_count;
    natural_t state[ARM_THREAD_STATE64_COUNT];
    char trailer[128];
} exception_request;

typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t result;
} exception_reply;
#pragma pack(pop)

/* dyld's (dyld_priv.h): where the shared cache is mapped */
extern const void *_dyld_get_shared_cache_range(size_t *length);

static mach_port_t port = MACH_PORT_NULL;
static pid_t child = 0;

void
crashwatch_child(pid_t pid)
{
    child = pid;
}

static uint64_t
strip(uint64_t pointer)
{
    return pointer & 0x0000007fffffffffULL;
}

static bool
read_task(mach_port_t task, uint64_t address, void *out, size_t size)
{
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(task, address, size, (mach_vm_address_t)out, &got) == KERN_SUCCESS && got == size;
}

/* the images loaded in the task, from dyld's list */
typedef struct {
    uint64_t base;
    char path[256];
} image;

static int
task_images(mach_port_t task, image *images, int max)
{
    struct task_dyld_info info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    struct dyld_all_image_infos all;
    if (!read_task(task, info.all_image_info_addr, &all, sizeof all))
        return 0;
    int n = 0;
    for (uint32_t i = 0; i < all.infoArrayCount && n < max; i++) {
        struct dyld_image_info ii;
        if (!read_task(task, (uint64_t)all.infoArray + i * sizeof ii, &ii, sizeof ii))
            break;
        images[n].base = (uint64_t)ii.imageLoadAddress;
        images[n].path[0] = 0;
        for (size_t k = 0; k + 1 < sizeof images[n].path; k++) {
            char c;
            if (!read_task(task, (uint64_t)ii.imageFilePath + k, &c, 1) || !c) {
                images[n].path[k] = 0;
                break;
            }
            images[n].path[k] = c;
            images[n].path[k + 1] = 0;
        }
        n++;
    }
    return n;
}

/* the image an address is in: the one loaded nearest below it */
static const image *
image_of(const image *images, int n, uint64_t address)
{
    const image *best = NULL;
    for (int i = 0; i < n; i++)
        if (images[i].base <= address && (!best || images[i].base > best->base))
            best = &images[i];
    return best;
}

static void
print_frame(int index, uint64_t address, const image *images, int n)
{
    const image *im = image_of(images, n, address);
    if (im)
        printf("crash:   %2d  %#llx  %s + %#llx\n", index, (unsigned long long)address, im->path,
               (unsigned long long)(address - im->base));
    else
        printf("crash:   %2d  %#llx\n", index, (unsigned long long)address);
}

/* the exception and the registers: printed first, before anything that might wait */
static void
report_exception(const arm_thread_state64_t *registers, exception_type_t exception, const int64_t *code, int code_count)
{
    printf("crash: exception %d", exception);
    for (int i = 0; i < code_count; i++)
        printf(" code[%d]=%#llx", i, (unsigned long long)code[i]);
    printf("\n");
    arm_thread_state64_t state = *registers;
    uint64_t pc = strip(arm_thread_state64_get_pc(state)), lr = strip(arm_thread_state64_get_lr(state));
    uint64_t fp = strip(arm_thread_state64_get_fp(state)), sp = strip(arm_thread_state64_get_sp(state));
    for (int i = 0; i < 29; i++)
        printf("%sx%-2d 0x%016llx%s", i % 4 ? " " : "crash: ", i, (unsigned long long)state.__x[i],
               i % 4 == 3 || i == 28 ? "\n" : "");
    printf("crash: pc %#llx lr %#llx fp %#llx sp %#llx\n", (unsigned long long)pc, (unsigned long long)lr,
           (unsigned long long)fp, (unsigned long long)sp);
    fflush(stdout);
}

/* the backtrace: the frames as far as the task's memory can be read */
static void
report_backtrace(mach_port_t task, const arm_thread_state64_t *registers)
{
    arm_thread_state64_t state = *registers;
    uint64_t pc = strip(arm_thread_state64_get_pc(state)), lr = strip(arm_thread_state64_get_lr(state));
    uint64_t fp = strip(arm_thread_state64_get_fp(state));
    static image images[1024];
    int n = task != MACH_PORT_NULL ? task_images(task, images, 1024) : 0;
    if (task == MACH_PORT_NULL)
        printf("crash: (no access to the task's memory: pc and lr only)\n");
    /* the shared cache's slide is the same in every process: the symbolizer maps cache
       addresses through the cache's map file with it */
    size_t cache_size = 0;
    const void *cache = _dyld_get_shared_cache_range(&cache_size);
    if (cache)
        printf("crash: shared cache %#llx size %#zx\n", (unsigned long long)(uintptr_t)cache, cache_size);
    printf("crash: backtrace\n");
    print_frame(0, pc, images, n);
    print_frame(1, lr, images, n);
    for (int i = 2; i < 64 && fp && task != MACH_PORT_NULL; i++) {
        uint64_t frame[2];
        if (!read_task(task, fp, frame, sizeof frame) || !strip(frame[1]))
            break;
        print_frame(i, strip(frame[1]), images, n);
        uint64_t next = strip(frame[0]);
        if (next <= fp)
            break;
        fp = next;
    }
    fflush(stdout);
}

static void *
watch(void *unused)
{
    (void)unused;
    for (;;) {
        exception_request request;
        memset(&request, 0, sizeof request);
        if (mach_msg(&request.head, MACH_RCV_MSG, 0, sizeof request, port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL) !=
            MACH_MSG_SUCCESS)
            continue;
        if (request.head.msgh_id == RAISE_STATE_IDENTITY_PROTECTED) {
            arm_thread_state64_t state;
            memset(&state, 0, sizeof state);
            memcpy(&state, request.state,
                   (request.state_count < ARM_THREAD_STATE64_COUNT ? request.state_count : ARM_THREAD_STATE64_COUNT) *
                       sizeof(natural_t));
            report_exception(&state, request.exception, request.code, 2);
            /* the task's memory, for the backtrace and its images, through its identity token */
            mach_port_t task = MACH_PORT_NULL;
            /* a crashed task's token is its corpse's, which converts only to a control port
               (allowed with developer mode, as in the VM); a read port otherwise */
            if (task_identity_token_get_task_port(request.task_token.name, TASK_FLAVOR_CONTROL, &task) != KERN_SUCCESS &&
                task_identity_token_get_task_port(request.task_token.name, TASK_FLAVOR_READ, &task) != KERN_SUCCESS &&
                /* or by its pid: for root, when it allows debugging (get-task-allow) */
                (!child || geteuid() != 0 || task_for_pid(mach_task_self(), child, &task) != KERN_SUCCESS))
                task = MACH_PORT_NULL;
            report_backtrace(task, &state);
            if (task != MACH_PORT_NULL)
                mach_port_deallocate(mach_task_self(), task);
            mach_port_deallocate(mach_task_self(), request.task_token.name);
        }
        /* not handled: the exception goes on, and the process dies as it would have */
        exception_reply reply;
        memset(&reply, 0, sizeof reply);
        reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request.head.msgh_bits), 0);
        reply.head.msgh_remote_port = request.head.msgh_remote_port;
        reply.head.msgh_size = sizeof reply;
        reply.head.msgh_id = request.head.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.result = KERN_FAILURE;
        mach_msg(&reply.head, MACH_SEND_MSG, sizeof reply, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return NULL;
}

void
crashwatch_spawnattr(posix_spawnattr_t *attr)
{
    if (port == MACH_PORT_NULL) {
        mach_port_options_t options;
        memset(&options, 0, sizeof options);
        options.flags = MPO_EXCEPTION_PORT | MPO_INSERT_SEND_RIGHT;
        if (mach_port_construct(mach_task_self(), &options, 0, &port) != KERN_SUCCESS) {
            port = MACH_PORT_NULL;
            return;
        }
        pthread_t t;
        pthread_create(&t, NULL, watch, NULL);
        pthread_detach(t);
    }
    posix_spawnattr_setexceptionports_np(
        attr,
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT |
            EXC_MASK_SOFTWARE | EXC_MASK_GUARD,
        port, (exception_behavior_t)(EXCEPTION_STATE_IDENTITY_PROTECTED | MACH_EXCEPTION_CODES), ARM_THREAD_STATE64);
}
