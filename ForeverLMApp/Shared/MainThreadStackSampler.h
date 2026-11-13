#ifndef MainThreadStackSampler_h
#define MainThreadStackSampler_h

#include <TargetConditionals.h>

#if TARGET_OS_OSX

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdint.h>

/// One snapshot of one thread's stack, taken from another thread of the same
/// process: `UIResponsivenessMonitor` samples the main thread with it while the
/// main thread is stalled.
///
/// It suspends `thread` and nothing else, reads its registers, walks the
/// frame-pointer chain and resumes it, all in a few microseconds. That is the
/// point of it: `/usr/bin/sample` suspends the whole task for each snapshot, and
/// on 2026-11-12 one of its runs held the app still for 5.6 s.
///
/// While `thread` is suspended it may hold any lock in the process, the malloc
/// lock included, so nothing in here allocates, takes a lock, logs or calls into
/// the Swift or Objective-C runtime. It is C for that reason: the Swift runtime
/// can allocate or lock behind an innocent-looking line (metadata, a release
/// that frees, exclusivity checks in Debug builds). Every frame pointer is
/// checked to lie inside the live part of the thread's stack, `[sp, stackHigh)`,
/// and to move up the stack, before it is read, so the walk cannot fault or loop.
///
/// - Parameters:
///   - thread: the thread to sample. Never the calling thread.
///   - stackLow, stackHigh: the thread's stack, `pthread_get_stackaddr_np` minus
///     `pthread_get_stacksize_np` up to `pthread_get_stackaddr_np`.
///   - frames: room for `capacity` addresses: the pc first, then each return
///     address up the chain, with pointer-authentication bits stripped.
///   - linkRegister: lr on arm64 (stripped), 0 elsewhere. A leaf function's
///     caller is only in lr; the caller of this function decides whether it is a
///     frame, after the thread runs again.
///   - suspendedTicks: how long the thread was held, in `mach_absolute_time` ticks.
/// - Returns: the number of addresses written, or -1 when the thread could not
///   be suspended or read (nothing written).
static inline int32_t foreverlm_sample_thread_stack(thread_t thread,
                                                    uintptr_t stackLow,
                                                    uintptr_t stackHigh,
                                                    uintptr_t *frames,
                                                    int32_t capacity,
                                                    uintptr_t *linkRegister,
                                                    uint64_t *suspendedTicks) {
    // User addresses on macOS fit in 47 bits. Return addresses saved by arm64e
    // system code carry a pointer-authentication signature above them, and a
    // Swift async frame sets bit 60 of the frame pointer it saves.
    const uintptr_t addressMask = 0x00007FFFFFFFFFFFULL;
    const uintptr_t word = sizeof(uintptr_t);

    *linkRegister = 0;
    *suspendedTicks = 0;
    if (capacity < 1 || stackHigh <= stackLow) return -1;

    uint64_t heldAt = mach_absolute_time();
    if (thread_suspend(thread) != KERN_SUCCESS) return -1;

    int32_t count = -1;
    uintptr_t pc = 0, fp = 0, sp = 0, lr = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        pc = (uintptr_t)arm_thread_state64_get_pc(state);
        fp = (uintptr_t)arm_thread_state64_get_fp(state);
        sp = (uintptr_t)arm_thread_state64_get_sp(state);
        lr = (uintptr_t)arm_thread_state64_get_lr(state);
        count = 0;
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t stateCount = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        pc = (uintptr_t)state.__rip;
        fp = (uintptr_t)state.__rbp;
        sp = (uintptr_t)state.__rsp;
        count = 0;
    }
#endif

    if (count == 0) {
        frames[count++] = pc & addressMask;
        *linkRegister = lr & addressMask;
        // Below sp is dead stack; a frame record can only lie between sp and the top.
        uintptr_t low = (sp > stackLow && sp < stackHigh) ? sp : stackLow;
        fp &= addressMask;
        while (count < capacity) {
            if (fp < low || fp > stackHigh - 2 * word || (fp & (word - 1)) != 0) break;
            uintptr_t callerFrame = ((const uintptr_t *)fp)[0] & addressMask;
            uintptr_t returnAddress = ((const uintptr_t *)fp)[1] & addressMask;
            if (returnAddress < 0x1000) break;
            frames[count++] = returnAddress;
            // The chain only ever runs up the stack; anything else is not a frame record.
            if (callerFrame <= fp) break;
            fp = callerFrame;
        }
    }

    thread_resume(thread);
    *suspendedTicks = mach_absolute_time() - heldAt;
    return count;
}

#endif /* TARGET_OS_OSX */

#endif /* MainThreadStackSampler_h */
