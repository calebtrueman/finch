/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The register frames behind Objective-C message forwarding and
 * -[NSInvocation invoke] (NSInvocation_Finch.m), in Apple's layout:
 *
 *   0    x0 ... x7      (8 bytes each)
 *   64   x8             (indirect result address)
 *   80   v0 ... v7      (16 bytes each)
 *   208  (unused)
 *   224  stack arguments
 *
 * ___CFFinchForwardingEntry is libobjc's forward handler: _objc_msgForward
 * tail-calls it with the message's registers untouched. It saves them,
 * calls __CFFinchForward(frame, stack args), and either returns the result
 * left in the frame or, when the C side asks for it (a forwarding target),
 * reloads the registers and tail-calls objc_msgSend.
 *
 * ___CFFinchInvoke(frame, fn, stack, stack size) loads the registers from a
 * frame, copies the stack arguments, calls fn, and stores x0, x1 and v0-v3
 * back into the frame.
 *
 * Both carry unwind information, so exceptions raised while forwarding (an
 * unrecognized selector) or by an invoked method unwind through them.
 */
    .text
    .p2align 2

    .globl ___CFFinchForwardingEntry
    .private_extern ___CFFinchForwardingEntry
___CFFinchForwardingEntry:
    .cfi_startproc
    pacibsp
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    .cfi_def_cfa w29, 16
    .cfi_offset w30, -8
    .cfi_offset w29, -16
    sub     sp, sp, #224
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    str     x8, [sp, #64]
    stp     q0, q1, [sp, #80]
    stp     q2, q3, [sp, #112]
    stp     q4, q5, [sp, #144]
    stp     q6, q7, [sp, #176]
    mov     x0, sp                  // frame
    add     x1, x29, #16            // the caller's stack arguments
    bl      ___CFFinchForward
    cbnz    w0, 1f
    ldp     x0, x1, [sp, #0]        // result registers
    ldp     q0, q1, [sp, #80]
    ldp     q2, q3, [sp, #112]
    mov     sp, x29
    ldp     x29, x30, [sp], #16
    retab
1:  ldp     x0, x1, [sp, #0]        // send again, to the receiver now in x0
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldr     x8, [sp, #64]
    ldp     q0, q1, [sp, #80]
    ldp     q2, q3, [sp, #112]
    ldp     q4, q5, [sp, #144]
    ldp     q6, q7, [sp, #176]
    mov     sp, x29
    ldp     x29, x30, [sp], #16
    autibsp
    b       _objc_msgSend
    .cfi_endproc

    .globl ___CFFinchInvoke
    .private_extern ___CFFinchInvoke
___CFFinchInvoke:
    .cfi_startproc
    pacibsp
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    .cfi_def_cfa w29, 16
    .cfi_offset w30, -8
    .cfi_offset w29, -16
    stp     x19, x20, [sp, #-16]!
    .cfi_offset w20, -24
    .cfi_offset w19, -32
    mov     x19, x0                 // frame
    mov     x20, x1                 // function
    add     x9, x3, #15             // stack arguments, 16-byte aligned
    and     x9, x9, #~15
    sub     sp, sp, x9
    mov     x10, #0
2:  cmp     x10, x3
    b.hs    3f
    ldrb    w11, [x2, x10]
    strb    w11, [sp, x10]
    add     x10, x10, #1
    b       2b
3:  ldp     x0, x1, [x19, #0]
    ldp     x2, x3, [x19, #16]
    ldp     x4, x5, [x19, #32]
    ldp     x6, x7, [x19, #48]
    ldr     x8, [x19, #64]
    ldp     q0, q1, [x19, #80]
    ldp     q2, q3, [x19, #112]
    ldp     q4, q5, [x19, #144]
    ldp     q6, q7, [x19, #176]
    blraaz  x20
    stp     x0, x1, [x19, #0]
    stp     q0, q1, [x19, #80]
    stp     q2, q3, [x19, #112]
    sub     sp, x29, #16
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    retab
    .cfi_endproc
