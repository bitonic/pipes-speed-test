.intel_syntax prefix

#define BUSY_LOOP 0

// Header files.
#include <asm/errno.h>
#include <asm/mman.h>
#include <asm/unistd.h>
#define F_SETPIPE_SZ 1031 // not in asm headers, define it manually
#define SPLICE_F_NONBLOCK	2

// The Linux system call API (limited to 4 arguments, the most this
// program uses). 64-bit registers are unsuffixed; 32-bit have an "e"
// suffix.
#define ARG1 %rdi
#define ARG1e %edi
#define ARG2 %rsi
#define ARG2e %esi
#define ARG3 %rdx
#define ARG3e %edx
#define ARG4 %r10
#define ARG4e %r10d
#define SYSCALL_RETURN %rax
#define SYSCALL_RETURNe %eax
#define SYSCALL_NUMBER %eax

// %rax, %rcx, %rdx, %ymm0-3 are general-purpose temporaries. Every
// other register is used for just one or two defined purposes; define
// symbolic names for them for readability. (Bear in mind that some of
// these will be clobbered sometimes, e.g. OUTPUT_LIMIT is clobbered
// by `syscall` because it's %r11.)
#define OUTPUT_PTR %rbx
#define BYTECODE_IP %rbp
#define SPILL %rsi
#define BYTECODE_GEN_PTR %rdi
#define REGEN_TRIGGER %r8
#define REGEN_TRIGGERe %r8d
#define YMMS_AT_WIDTH %r9
#define YMMS_AT_WIDTHe %r9d
#define BUZZ %r10
#define BYTECODE_NEG_LEN %r10
#define FIZZ %r11
#define FIZZe %r11d
#define OUTPUT_LIMIT %r11
#define BYTECODE_END %r12
#define BYTECODE_START %r13
#define BYTECODE_STARTe %r13d
#define PIPE_SIZE %r13
#define LINENO_WIDTH %r14
#define LINENO_WIDTHe %r14d
#define GROUPS_OF_15 %r15
#define GROUPS_OF_15e %r15d
#define LINENO_LOW %ymm4
#define LINENO_MID %ymm5
#define LINENO_MIDx %xmm5
#define LINENO_TOP %ymm6
#define LINENO_TOPx %xmm6
#define LINENO_MID_TEMP %ymm7
#define ENDIAN_SHUFFLE %ymm8
#define ENDIAN_SHUFFLEx %xmm8
#define LINENO_LOW_INCR %ymm9
#define LINENO_LOW_INCRx %xmm9

// The last six vector registers are used to store constants, to avoid
// polluting the cache by loading their values from memory.
#define LINENO_LOW_INIT %ymm10
#define LINENO_MID_BASE %ymm11
#define LINENO_TOP_MAX %ymm12
#define ASCII_OFFSET %ymm13
#define ASCII_OFFSETx %xmm13
#define BIASCII_OFFSET %ymm14
#define BASCII_OFFSET %ymm15


// Global variables.
.bss
.align 4 << 20
// The most important global variables are the IO buffers. There are
// two of these, each with 2MiB of memory allocated (not all of it is
// used, but putting them 2MiB apart allows us to simplify the page
// table; this gives a 30% speedup because page table contention is
// one of the main limiting factors on the performance).
io_buffers:
.zero 2 * (2 << 20)
// The remaining 2MiB of memory stores everything else:
iovec_base:          // I/O config buffer for vmsplice(2) system call
.zero 16
error_write_buffer:  // I/O data buffer for write(2) system call
.zero 1
.p2align 9,0
bytecode_storage:    // the rest is a buffer for storing bytecode
.zero (2 << 20) - 512


// The program starts here. It doesn't use the standard library (or
// indeed any libraries), so the start point is _start, not main.
.text
.globl _start
_start:

// This is an AVX2 program, so check for AVX2 support by running an
// AVX2 command. This is a no-op, but generates SIGILL if AVX2 isn't
// supported.
vpand %ymm0, %ymm0, %ymm0

// Initialize constant registers to their constant values.
vmovdqa LINENO_LOW_INIT, [%rip + lineno_low_init]
vmovdqa LINENO_MID_BASE, [%rip + lineno_mid_base]
vmovdqa LINENO_TOP_MAX, [%rip + lineno_top_max]
vmovdqa ASCII_OFFSET, [%rip + ascii_offset]
vmovdqa BIASCII_OFFSET, [%rip + biascii_offset]
vmovdqa BASCII_OFFSET, [%rip + bascii_offset]

// Initialize global variables to their initial values.
vmovdqa ENDIAN_SHUFFLE, [%rip + endian_shuffle_init]
vmovdqa LINENO_TOP, [%rip + lineno_top_init]

// Check the size of the L2 cache.
//
// This uses the CPUID interface. To use it safely, check what range
// of command numbers is legal; commands above the legal range have
// undefined behaviour, commands within the range might not be
// implemented but will return all-zeros rather than undefined values.
// CPUID clobbers a lot of registers, including some that are normally
// call-preserved, so this must be done first.
mov %eax, 0x80000000 // asks which CPUID extended commands exist
cpuid                // returns the highest supported command in %eax
cmp %eax, 0x80000006 // does 0x80000006 give defined results?
jb bad_cpuid_error

mov %eax, 0x80000006 // asks about the L2 cache size
cpuid                // returns size in KiB in the top half of %ecx
shr %ecx, 16
jz bad_cpuid_error   // unsupported commands return all-0s

// Calculate the desired pipe size, half the size of the L2 cache.
// This value is chosen so that the processor can hold a pipeful of
// data being output, plus a pipeful of data being calculated, without
// needing to resort to slow L3 memory operations.
shl %ecx, 10 - 1     // convert KiB to bytes, then halve
mov PIPE_SIZE, %rcx

// Ask the kernel to resize the pipe on standard output.
mov ARG1e, 1
mov ARG2e, F_SETPIPE_SZ
mov ARG3e, %ecx
mov SYSCALL_NUMBER, __NR_fcntl
syscall
cmp SYSCALL_RETURNe, -EBADF
je pipe_error
cmp SYSCALL_RETURNe, -EPERM
je pipe_perm_error
call exit_on_error
cmp SYSCALL_RETURN, PIPE_SIZE
jne pipe_size_mismatch_error

// Ask the kernel to defragment the physical memory backing the BSS
// (read-write data) segment. This simplifies the calculations needed
// to find physical memory addresses, something that both the kernel
// and processor would otherwise spend a lot of time doing, and
// speeding the program up by 30%.
lea ARG1, [%rip + io_buffers]
mov ARG2e, 3 * (2 << 20)
mov ARG3e, MADV_HUGEPAGE
mov SYSCALL_NUMBER, __NR_madvise
syscall
call exit_on_error

// From now on, OUTPUT_PTR is permanently set to the memory location
// where the output is being written. This starts at the start of the
// first I/O buffer.
lea OUTPUT_PTR, [%rip + io_buffers]


///// First phase of output
//
// The FizzBuzz output is produced in three distinct phases. The first
// phase is trivial; just a hardcoded string, that's left in the
// output buffer, to be output at the end of the second phase.

first_phase:

.section .rodata
fizzbuzz_intro:
.ascii "1\n2\nFizz\n4\nBuzz\nFizz\n7\n8\nFizz\n"
.text
vmovdqu %ymm0, [%rip + fizzbuzz_intro]
vmovdqu [OUTPUT_PTR], %ymm0
add OUTPUT_PTR, 30


///// Second phase of output
//
// This is a routine implementing FizzBuzz in x86-64+AVX2 assembler in
// a fairly straightforward and efficient way. This isn't as fast as
// the third-phase algorithm, and can't handle large numbers, but will
// introduce some of the basic techniques this program uses.

second_phase_init:

// The outer loop of the whole program breaks the FizzBuzz output into
// sections where all the line numbers contain the same number of
// digits. From now on, LINENO_WIDTH tracks the number of digits in
// the line number. This is currently 2; it ranges from 2-digit
// numbers to 18-digit numbers, and then the program ends.
mov LINENO_WIDTHe, 2

// GROUPS_OF_15 is permanently set to the number of groups of 15 lines
// that exist at this line number width; it's multiplied by 10 whenever
// LINENO_WIDTH is incremented.
//
// A general note about style: often the program uses numbers that are
// statically known to fit into 32 bits, even in a register that's
// conceptually 64 bits wide (like this one). In such cases, the
// 32-bit and 64-bit versions of a command will be equivalent (as the
// 32-bit version zero-extends to 64-bits on a 64-bit processor); this
// program generally uses the 32-bit version, both because it
// sometimes encodes to fewer bytes (saving cache pressure), and
// because some processors recognise zeroing idioms only if they're 32
// bits wide.
mov GROUPS_OF_15e, 6

// Some constants used throughout the second phase, which permanently
// stay in their registers. Note that short string literals can be
// stored in normal integer registers - the processor doesn't care.
mov FIZZ, 0x0a7a7a6946  // "Fizz\n"
mov BUZZ, 0x0a7a7a7542  // "Buzz\n"

.section .rodata
.p2align 5, 0
second_phase_constants:
.byte 0, 0, 0, 0, 0, 0, 0, 0
.byte 1, 0, 0, 0, 0, 0, 0, 0
.text
vmovdqa %xmm3, [%rip + second_phase_constants]

// This program makes extensive use of a number format that I call
// "high-decimal". This is a version of decimal where the digit 0 is
// encoded as the byte 246, the digit 1 as the byte 247, ..., the
// digit 9 as the byte 255. The bytes are stored in the normal
// endianness for the processor (i.e. least significant first), and
// padded to a known length (typically 8 digits) with leading zeroes.
//
// The point of high-decimal is that it allows us to use arithmetic
// operators intended for binary on high-decimal numbers, and the
// carries will work the same way (i.e. the same digits will carry,
// although carries will be 0-based rather than 246-based); all that's
// required is to identify the digits that carried and add 246 to
// them. That means that the processor's binary ALU can be used to do
// additions directly in decimal - there's no need for loops or
// anything like that, and no need to do binary/decimal conversions.
//
// The first use for high-decimal is to store the line number during
// the second phase (it's stored differently in the third phase).
// It's stored it in the top half of %xmm1 (although it's only 64 bits
// wide, it needs to be ine a vector register so that it can be
// inerpreted as 8 x 8 bits when necessary; general-purpose registers
// can't do that). The bottom half of %xmm1 is unused, and frequently
// overwritten with arbitrary data.
.section .rodata
line_number_init:
#define REP8(x) x,x,x,x,x,x,x,x
.byte REP8(0)
.byte 246, 247, 246, 246, 246, 246, 246, 246
.text
vmovdqa %xmm1, [%rip + line_number_init]

// Writing line numbers is nontrivial because x86-64 is little-endian
// but FizzBuzz output is big-endian; also, leading zeroes aren't
// allowed. ENDIAN_SHUFFLE is used to fix both these problems; when
// used to control the vector shuffler, it reverses the order of a
// vector register, and rotates the elements to put the first digit
// (based on LINENO_WIDTH) into the first byte. (This method is used
// by both the second and third phases; the second phase uses only the
// bottom half, with the top half used by the third phase, but they
// are both initialized together.)
.section .rodata
endian_shuffle_init:
.byte 9, 8, 7, 6, 5, 4, 3, 2
.byte 1, 0, 255, 254, 253, 252, 251, 250
.byte 3, 2, 1, 0, 255, 254, 253, 252
.byte 251, 250, 249, 248, 247, 246, 245, 244
.text


second_phase_per_width_init:

// The second phase writing routines are macros.
//
// Fizz and Buzz are trivial. (This writes a little beyond the end of
// the string, but that's OK; the next line will overwrite them.)
#define WRITE_FIZZ   mov [OUTPUT_PTR], FIZZ; add OUTPUT_PTR, 5
#define WRITE_BUZZ   mov [OUTPUT_PTR], BUZZ; add OUTPUT_PTR, 5

// For FizzBuzz, output 32 bits of FIZZ to write "Fizz" with no
// newline, then write a "Buzz" after that.
#define WRITE_FIZZBUZZ \
  mov [OUTPUT_PTR], FIZZe; mov [OUTPUT_PTR + 4], BUZZ; \
  add OUTPUT_PTR, 9

// To write a line number, add 58 to each byte of the line number
// %xmm1, fix the endianness and width with a shuffle, and write a
// final newline.
.section .rodata
ascii_offset:
.byte REP8(58), REP8(58), REP8(58), REP8(58)
.text
#define WRITE_LINENO \
  vpaddb %xmm0, ASCII_OFFSETx, %xmm1; \
  vpshufb %xmm0, %xmm0, ENDIAN_SHUFFLEx; \
  vmovdqu [OUTPUT_PTR], %xmm0; \
  lea OUTPUT_PTR, [OUTPUT_PTR + LINENO_WIDTH + 1]; \
  mov byte ptr [OUTPUT_PTR - 1], 10  // 10 = newline

// Incrementing the line number is fairly easy: add 1 (in the usual
// binary notation, taken from %xmm3) to the high-decimal number, then
// convert any bytes that produced a carry to high-decimal 0s by
// max-ing with 246.
//
// Normally I'd use a separate constant for this, but there randomly
// happens to be an %xmm register with 246s in its top half already
// (it's intended for an entirely different purpose, but it'll do for
// this one too).
#define INC_LINENO \
  vpaddq %xmm1, %xmm3, %xmm1; vpmaxub %xmm1, LINENO_TOPx, %xmm1

// Avoid modulus tests by unrolling the FizzBuzz by 15. (Bear in mind
// that this starts at 10, not 0, so the pattern will have a different
// phase than usual.)
mov %ecx, GROUPS_OF_15e
fifteen_second_phase_fizzbuzz_lines:
WRITE_BUZZ; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_FIZZ; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_FIZZBUZZ; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_FIZZ; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_BUZZ; INC_LINENO
WRITE_FIZZ; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_LINENO; INC_LINENO
WRITE_FIZZ; INC_LINENO
dec %ecx
jnz fifteen_second_phase_fizzbuzz_lines

second_phase_increment_width:

lea GROUPS_OF_15e, [GROUPS_OF_15 + GROUPS_OF_15 * 4]
add GROUPS_OF_15e, GROUPS_OF_15e
inc LINENO_WIDTHe

// Increment every element of the low half of ENDIAN_SHUFFLE to
// adjust it for the new width, while leaving the top half unchanged.
vpcmpeqb %xmm0, %xmm0, %xmm0
vpsubb ENDIAN_SHUFFLE, ENDIAN_SHUFFLE, %ymm0

// The second phase handles line numbers with 2 to 5 digits.
cmp LINENO_WIDTHe, 6
jne second_phase_per_width_init

///// The output routine
//
// Most FizzBuzz routines produce output with `write` or a similar
// system call, but these have the disadvantage that they need to copy
// the data being output from userspace into kernelspace. It turns out
// that when running full speed (as seen in the third phase), FizzBuzz
// actually runs faster than `memcpy` does, so `write` and friends are
// unusable when aiming for performance - this program runs five times
// faster than an equivalent that uses `write`-like system calls.
//
// To produce output without losing speed, the program therefore needs
// to avoid copies, or at least do them in parallel with calculating
// the next block of output. This can be accomplished with the
// `vmsplice` system call, which tells the kernel to place a reference
// to a buffer into a pipe (as opposed to copying the data into the
// pipe); the program at the other end of this pipe will then be able
// to read the output directly out of this program's memory, with no
// need to copy the data into kernelspace and then back into
// userspace. In fact, it will be reading out of this program's
// processor's L2 cache, without main memory being touched at all;
// this is the secret to high-performance programming, because the
// cache is much faster than main memory is.
//
// Of course, it's therefore important to avoid changing the output
// buffer until the program connected to standard output has actually
// read it all. This is why the pipe size needed to be set earlier; as
// long as the amount of output is always at least as large as the
// pipe size, successfully outputting one buffer will ensure that none
// of the other buffer is left in the pipe, and thus it's safe to
// overwrite the memory that was previosuly output. There is some need
// to jump through hoops later on to make sure that `swap_buffers` is
// never called with less than one pipeful of data, but it's worth it
// to get the huge performance boost.

mov %rdx, OUTPUT_PTR
and %edx, (2 << 20) - 1

call swap_buffers
jmp third_phase_init

// Takes the amount of data to output in %rdx, and outputs from the
// buffer containing OUTPUT_PTR.
swap_buffers:
and OUTPUT_PTR, -(2 << 20)  // rewind to the start of the buffer
mov [%rip + iovec_base], OUTPUT_PTR
mov [%rip + iovec_base + 8], %rdx
mov ARG1e, 1
lea ARG2, [%rip + iovec_base]
mov ARG3e, 1
#if BUSY_LOOP
mov ARG4e, SPLICE_F_NONBLOCK
#else
xor ARG4e, ARG4e
#endif

// As with most output commands, vmsplice can do a short write
// sometimes, so it needs to be called in a loop in order to ensure
// that all the output is actually sent.
1: mov SYSCALL_NUMBER, __NR_vmsplice
syscall
#if BUSY_LOOP
cmp SYSCALL_RETURN, -0x00B // EINVAL
je 1b
#endif
call exit_on_error
add [ARG2], SYSCALL_RETURN
sub [ARG2 + 8], SYSCALL_RETURN
jnz 1b

xor OUTPUT_PTR, (2 << 20)  // swap to the other buffer
ret


///// Third phase of output
//
// This is the heart of this program. It aims to be able to produce a
// sustained output rate of 64 bytes of FizzBuzz per four clock cycles
// in its main loop (with frequent breaks to do I/O, and rare breaks
// to do more expensive calculations).
//
// The third phase operates primarily using a bytecode interpreter; it
// generates a program in "FizzBuzz bytecode", for which each byte of
// bytecode generates one byte of output. The bytecode language is
// designed so that it can be interpreted using SIMD instructions; 32
// bytes of bytecode can be loaded from memory, interpreted, and have
// its output stored back into memory using just four machine
// instructions. This makes it possible to speed up the FizzBuzz
// calculations by hardcoding some of the calculations into the
// bytecode (this is similar to how JIT compilers can create a version
// of the program with some variables hardcoded, and throw it away on
// the rare occasions that those variables' values change).

third_phase_init:

// Reinitialize ENDIAN_SHUFFLE by copying the initializer stored in
// its high half to both halves. This works in the same way as in the
// second phase.
vpermq ENDIAN_SHUFFLE, ENDIAN_SHUFFLE, 0xEE

// Up to this point, PIPE_SIZE has held the size of the pipe. In order
// to save on registers, the pipe size is from now on encoded via the
// location in which the bytecode program is stored; the bytecode is
// started at iovec_base + PIPE_SIZE (which will be somewhere within
// bytecode_storage), so the same register can be used to find the
// bytecode and to remember the pipe size.
lea %rax, [%rip + iovec_base]
add BYTECODE_START, %rax  // BYTECODE_START is a synonym for PIPE_SIZE

// The bytecode program always holds instructions to produce exactly
// 600 lines of FizzBuzz. At width 6, those come to 3800 bytes long.
lea BYTECODE_END, [BYTECODE_START + 3800]

mov REGEN_TRIGGER, -1  // irrelevant until much later, explained there


third_phase_per_width_init:

// Calculate the amount of output at this LINENO_WIDTH. The result
// will always be divisible by 32, and thus is stored as the number of
// 32-byte units at this width; storing it in bytes would be more
// convenient, but sadly would overflow a 64-bit integer towards the
// end of the program.
lea %ecx, [LINENO_WIDTH * 8 + 47]   // bytes per 15 lines
mov YMMS_AT_WIDTH, GROUPS_OF_15
shr YMMS_AT_WIDTH, 5   // to avoid overflow, divide by 32 first
imul YMMS_AT_WIDTH, %rcx

// This program aims to output 64 bytes of output per four clock
// cycles, which it achieves via a continuous stream of 32-byte writes
// calculated by the bytecode program. One major complication here is
// that the 32-byte writes won't correspond to lines of FizzBuzz; a
// single processor instruction may end up outputting multiple
// different line numbers. So it's no longer possible to have a simple
// line number register, like it was in the second phase.
//
// Instead, the program stores an *approximation* of the line number,
// which is never allowed to differ by 100 or more from the "actual"
// line number; the bytecode program is responsible for fixing up the
// approximation to work out the correct line number to output (this
// allows the same CPU instruction to output digits from multiple
// different line numbers, because the bytecode is being interpreted
// in a SIMD way and thus different parts of the bytecode can fix the
// line number up differently within a single instruction.
//
// The line number is split over three processor registers:
// - LINENO_LOW: stores the line number modulo 200
// - LINENO_MID: stores the hundreds to billions digits
// - LINENO_TOP: stores the ten-billions and more significant digits
// (The parity of the 100s digit is duplicated between LINENO_MID and
// LINENO_LOW; this allows a faster algorithm for LINENO_MID updates.)
//
// Because there's only a need to be within 100 of the real line
// number, the algorithm for updating the line numbers doesn't need to
// run all that often (saving processor cycles); it runs once every
// 512 bytes of output, by simply adding a precalculated value
// (LINENO_LOW_INCR) to LINENO_LOW, then processing the carry to
// LINENO_MID (see later for LINENO_TOP). The amount by which the line
// number increases per 512 bytes of output is not normally going to
// be an integer; LINENO_LOW is therefore stored as a 64-bit fixpoint
// number (in which 2**64 represents "200", e.g. 2**63 would be the
// representation of "the line number is 100 mod 200"), in order to
// delay the accumulation of rounding errors as long as possible. It's
// being stored in a vector register, so there are four copies of its
// value; two of them have 50 (i.e 2**62) added, and two of them have
// 50 subtracted, in order to allow for more efficient code to handle
// the carry to LINENO_MID. Additionally, LINENO_LOW is interpreted as
// a signed number (an older version of this program was better at
// checking for signed than unsigned overflow and I had no reason to
// change).
//
// LINENO_LOW and LINENO_MID are reset every LINENO_WIDTH increase
// (this is because the program can calculate "past" the width
// increase due to not being able to break out of every instruction of
// the main loop, which may cause unwanted carries into LINENO_MID and
// force a reset).

.section .rodata
lineno_low_init:
.byte 0, 0, 0, 0, 0, 0, 0, 192
.byte 0, 0, 0, 0, 0, 0, 0, 64
.byte 0, 0, 0, 0, 0, 0, 0, 192
.byte 0, 0, 0, 0, 0, 0, 0, 64
.text
vmovdqa LINENO_LOW, LINENO_LOW_INIT

// %ecx is the number of bytes in 15 lines. That means that the number
// of 200-line units in 512 bytes is 38.4/%ecx, i.e. 384/(%ecx*10).
// Multiply by 2**64 (i.e. 384*2**64/(%ecx*10) to get LINENO_LOW_INCR.
lea %ecx, [%rcx + %rcx * 4]
add %ecx, %ecx
mov %edx, 384
xor %eax, %eax
div %rcx  // 128-bit divide, %rax = %rdx%rax / %rcx
vpxor LINENO_LOW_INCR, LINENO_LOW_INCR, LINENO_LOW_INCR
vpinsrq LINENO_LOW_INCRx, LINENO_LOW_INCRx, %rax, 0
vpermq LINENO_LOW_INCR, LINENO_LOW_INCR, 0

// LINENO_MID is almost stored in high-decimal, as four eight-digit
// numbers. However, the number represented is the closest line number
// that's 50 mod 100, stored as the two closest multiples of 100 (e.g.
// if the true line number is 235, it's approximated as 250 and then
// stored using the representations for 200 and 300), which is why
// LINENO_LOW needs the offsets of 50 and -50 to easily do a carry. A
// ymm vector holds four 64-bit numbers, two of which hold the value
// that's 0 mod 200, two which hold the value that's 100 mod 200. So
// carries on it are handled using a vector of mostly 246s, with 247s
// in the two locations which are always odd.
.section .rodata
lineno_mid_base:
.byte 246, 246, 246, 246, 246, 246, 246, 246
.byte 247, 246, 246, 246, 246, 246, 246, 246
.byte 246, 246, 246, 246, 246, 246, 246, 246
.byte 247, 246, 246, 246, 246, 246, 246, 246
.text

// This code is some fairly complex vector manipulation to initialise
// LINENO_MID to a power of 10 (handling the case where LINENO_WIDTH
// is so high that the hundreds to billions digits are all zeroes).
mov %edx, 1
mov %eax, 11
sub %eax, LINENO_WIDTHe
cmovbe %eax, %edx
shl %eax, 3
vpxor %xmm0, %xmm0, %xmm0
vpinsrq %xmm0, %xmm0, %rax, 0
vpermq %ymm0, %ymm0, 0
vpcmpeqb LINENO_MID, LINENO_MID, LINENO_MID
vpsrlq LINENO_MID, LINENO_MID, %xmm0
vpmaxub LINENO_MID, LINENO_MID_BASE, LINENO_MID
vpermq %ymm0, LINENO_MID_BASE, 0x55
vpsubb %ymm0, %ymm0, LINENO_MID_BASE
vpaddq LINENO_MID, LINENO_MID, %ymm0
vpmaxub LINENO_MID, LINENO_MID_BASE, LINENO_MID

// LINENO_TOP doesn't need to be initialized for new widths, because
// an overrun by 100 lines is possible, but by 10 billion lines isn't.
// The format consists of two 64-bit sections that hold high-decimal
// numbers (these are always the same as each other), and two that
// hold constants that are used by the bytecode generator.
.section .rodata
lineno_top_init:
.byte 198, 197, 196, 195, 194, 193, 192, 191
.byte 246, 246, 246, 246, 246, 246, 246, 246
.byte 190, 189, 188, 187, 186, 185, 184, 183
.byte 246, 246, 246, 246, 246, 246, 246, 246
.text

// When moving onto a new width, start at the start of the bytecode
// program.
mov BYTECODE_IP, BYTECODE_START


// Generating the bytecode program
//
// The bytecode format is very simple (in order to allow it to be
// interpreted in just a couple of machine instructions):
// - A negative byte represents a literal character (e.g. to produce
//   a literal 'F', you use the bytecode -'F', i.e. -70 = 0xba)
// - A byte 0..7 represents the hundreds..billions digit of the line
//   number respectively, and asserts that the hundreds digit of the
//   line number is even
// - A byte 8..15 represents the hundreds..billions digit of the line
//   number respectively, and asserts that the hundreds digit of the
//   line number is odd
//
// In other words, the bytecode program only ever needs to read from
// LINENO_MID; the information stored in LINENO_LOW and LINENO_TOP
// therefore has to be hardcoded into it. The program therefore needs
// to be able to generate 600 lines of output (as the smallest number
// that's divisible by 100 to be able to hardcode the two low digits,
// 200 to be able to get the assertions about the hundreds digits
// correct, and 3 and 5 to get the Fizzes and Buzzes in the right
// place).

generate_bytecode:

mov BYTECODE_GEN_PTR, BYTECODE_START

// FIZZ and BUZZ work just like in the second phase, except that they
// are now bytecode programs rather than ASCII.
mov FIZZ, 0xf6868697ba  // -"Fizz\n"
mov BUZZ, 0xf686868bbe  // -"Buzz\n"

// %ymm2 holds the bytecode for outputting the hundreds and more
// significant digits of a line number. The most significant digits of
// this can be obtained by converting LINENO_TOP from high-decimal to
// the corresponding bytecode, which is accomplished by subtracting
// from 198 (i.e. 256 - 10 - '0'). The constant parts of LINENO_TOP
// are 198 minus the bytecode for outputting the hundreds to billions
// digit of a number; this makes it possible for a single endian
// shuffle to deal with all 16 of the mid and high digits at once.
.section .rodata
bascii_offset:
.byte REP8(198), REP8(198), REP8(198), REP8(198)
.text
vpsubb %ymm2, BASCII_OFFSET, LINENO_TOP
vpshufb %ymm2, %ymm2, ENDIAN_SHUFFLE

#define GEN_FIZZ  mov [BYTECODE_GEN_PTR], FIZZ; add BYTECODE_GEN_PTR, 5
#define GEN_BUZZ  mov [BYTECODE_GEN_PTR], BUZZ; add BYTECODE_GEN_PTR, 5
#define GEN_FIZZBUZZ \
  mov [BYTECODE_GEN_PTR], FIZZe; \
  mov [BYTECODE_GEN_PTR + 4], BUZZ; add BYTECODE_GEN_PTR, 9
#define GEN_LINENO(units_digit) \
  vmovdqu [BYTECODE_GEN_PTR], %xmm2; \
  lea BYTECODE_GEN_PTR, [BYTECODE_GEN_PTR + LINENO_WIDTH + 1]; \
  mov [BYTECODE_GEN_PTR - 3], %al; \
  mov word ptr [BYTECODE_GEN_PTR - 2], 0xf6d0 - units_digit

// The bytecode generation loop is unrolled to depth 30, allowing the
// units digits to be hardcoded. The tens digit is stored in %al, and
// incremented every ten lines of output. The parity of the hundreds
// digit is stored in %ymm2: one half predicts the hundreds digit to
// be even, the other to be odd, and the halves are swapped every time
// the tens digit carries (ensuring the predictions are correct).
mov %eax, 0xd0
jmp 2f
inc_tens_digit:
cmp %al, 0xc7
je 1f  // jumps every 10th execution, therefore predicts perfectly
dec %eax
ret
1: mov %eax, 0xd0
vpermq %ymm2, %ymm2, 0x4e
ret

2: mov %ecx, 20
thirty_bytecode_lines:
GEN_BUZZ
GEN_LINENO(1)
GEN_FIZZ
GEN_LINENO(3)
GEN_LINENO(4)
GEN_FIZZBUZZ
GEN_LINENO(6)
GEN_LINENO(7)
GEN_FIZZ
GEN_LINENO(9)
call inc_tens_digit
GEN_BUZZ
GEN_FIZZ
GEN_LINENO(2)
GEN_LINENO(3)
GEN_FIZZ
GEN_BUZZ
GEN_LINENO(6)
GEN_FIZZ
GEN_LINENO(8)
GEN_LINENO(9)
call inc_tens_digit
GEN_FIZZBUZZ
GEN_LINENO(1)
GEN_LINENO(2)
GEN_FIZZ
GEN_LINENO(4)
GEN_BUZZ
GEN_FIZZ
GEN_LINENO(7)
GEN_LINENO(8)
GEN_FIZZ
call inc_tens_digit
dec %ecx
jnz thirty_bytecode_lines

generate_bytecode_overrun_area:

// Duplicate the first 512 bytes of the bytecode program at the end,
// so that there's no need to check to see whether BYTECODE_IP needs
// to be looped back to the start of the program any more than once
// per 512 bytes
mov %rax, BYTECODE_START
#define COPY_64_BYTECODE_BYTES(offset) \
  vmovdqa %ymm0, [%rax + offset]; \
  vmovdqa %ymm3, [%rax + (offset + 32)]; \
  vmovdqu [BYTECODE_GEN_PTR + offset], %ymm0; \
  vmovdqu [BYTECODE_GEN_PTR + (offset + 32)], %ymm3
COPY_64_BYTECODE_BYTES(0)
COPY_64_BYTECODE_BYTES(64)
COPY_64_BYTECODE_BYTES(128)
COPY_64_BYTECODE_BYTES(192)
COPY_64_BYTECODE_BYTES(256)
COPY_64_BYTECODE_BYTES(320)
COPY_64_BYTECODE_BYTES(384)
COPY_64_BYTECODE_BYTES(448)


// Preparing for the main loop
//
// Work out how long the main loop is going to iterate for.
// OUTPUT_LIMIT holds the address just beyond the end of the output
// that the main loop should produce. The aim here is to produce
// exactly one pipeful of data if possible, but to stop earlier if
// there's a change in digit width (because any output beyond that
// point will be useless: the bytecode will give it the wrong number
// of digits).
calculate_main_loop_iterations:

// Extract the pipe size from BYTECODE_START, in 32-byte units.
// During this calculation, OUTPUT_LIMIT holds the amount of output
// produced, rather than an address like normal.
mov OUTPUT_LIMIT, BYTECODE_START
lea %rdx, [%rip + iovec_base]
sub OUTPUT_LIMIT, %rdx
shr OUTPUT_LIMIT, 5

// Reduce the output limit to the end of this width, if it would be
// higher than that.
cmp OUTPUT_LIMIT, YMMS_AT_WIDTH
cmovae OUTPUT_LIMIT, YMMS_AT_WIDTH

// If there's already some output in the buffer, reduce the amount
// of additional output produced accordingly (whilst ensuring that
// a multiple of 512 bytes of output is produced).
//
// This would be buggy if the YMMS_AT_WIDTH limit were hit at the
// same time, but that never occurs as it would require two width
// changes within one pipeful of each other, and 9000000 lines of
// FizzBuzz is much more than a pipeful in size.
mov %rax, OUTPUT_PTR
and %eax, ((2 << 20) - 1) & -512
shr %eax, 5
sub OUTPUT_LIMIT, %rax

// The amount of output to produce is available now, and won't be
// later, so subtract it from the amount of output that needs to
// be produced now.
sub YMMS_AT_WIDTH, OUTPUT_LIMIT

// Return OUTPUT_LIMIT back to being a pointer, not an amount.
shl OUTPUT_LIMIT, 5
add OUTPUT_LIMIT, OUTPUT_PTR

prepare_main_loop_invariants:

// To save one instruction in the bytecode interpreter (which is very
// valuable, as it runs every second CPU cycle), LINENO_MID_TEMP is
// used to store a reformatted version of LINENO_MID, in which each
// byte is translated from high-decimal to ASCII, and the bytecode
// command that would access that byte is added to the result (e.g.
// the thousands digit for the hundreds-digits-odd version has 10
// added to convert from high-decimal to a pure number, '0' added to
// convert to ASCII, then 9 added because that's the bytecode command
// to access the thousands digit when the hundreds digit is odd, so
// the amount added is 10 + '0' + 9 = 57).
//
// LINENO_MID_TEMP is updated within the main loop, immediately after
// updating LINENO_MID, but because the bytecode interpreter reads
// from it it needs a valid value at the start of the loop.
.section .rodata
biascii_offset:
.byte 58, 59, 60, 61, 62, 63, 64, 65
.byte 66, 67, 68, 69, 70, 71, 72, 73
.byte 58, 59, 60, 61, 62, 63, 64, 65
.byte 66, 67, 68, 69, 70, 71, 72, 73
.text
vpaddb LINENO_MID_TEMP, BIASCII_OFFSET, LINENO_MID

// To save an instruction, precalculate minus the length of the
// bytecode. (Although the value of this is determined entirely by
// LINENO_WIDTH, the register it's stored in gets clobbered by
// system calls and thus needs to be recalculated each time.)
mov BYTECODE_NEG_LEN, BYTECODE_START
sub BYTECODE_NEG_LEN, BYTECODE_END


// The main loop

// The bytecode interpreter consists of four instructions:
// 1. Load the bytecode from memory into %ymm2;
// 2. Use it as a shuffle mask to shuffle LINENO_MID_TEMP;
// 3. Subtract the bytecode from the shuffle result;
// 4. Output the result of the subtraction.
//
// To see why this works, consider two cases. If the bytecode wants to
// output a literal character, then the shuffle will produce 0 for
// that byte (in AVX2, a shuffle with a a negative index produces an
// output of 0), and subtracting the bytecode from 0 then produces the
// character (because the bytecode encoded minus the character). If
// the bytecode instead wants to output a digit, then the shuffle will
// fetch the relevant digit from LINENO_MID_TEMP (which is the desired
// ASCII character plus the bytecode instruction that produces it),
// and subtract the bytecode instruction to just produce the character
// on its own.
//
// This produces an exactly correct line number as long as the line
// number approximation is within 100 of the true value: it will be
// correct as long as the relevant part of LINENO_MID is correct, and
// the worst case is for LINENO_MID to be storing, say, 200 and 300
// (the representation of 250) when the true line number is 400. The
// value in LINENO_MID specifically can be up to 50 away from the
// value of the line number as recorded by LINENO_MID and LINENO_LOW
// together, so as long as the line number registers are within 100,
// LINENO_MID will be within 150 (which is what is required).
//
// This doesn't update the bytecode instruction pointer or the pointer
// into the output buffer; those are updated once every 512 bytes (and
// to "advance the instruction pointer" the rest of the time, the main
// loop is unrolled, using hardcoded offsets with the pointer updates
// baked in).
//
// The bytecode instruction pointer itself is read from %rdx, not
// BYTECODE_IP, so that mid-loop arithmetic on BYTECODE_IP won't cause
// the interpreter to break.
//
// It's important to note one potential performance issue with this
// code: the read of the bytecode from memory is not only misalignable
// (`vmovdqu`); it splits a cache line 3/8 of the time. This causes L1
// split-load penalties on the 3/8 cycles where it occurs. I am not
// sure whether this actually reduces the program's performance in
// practice, or whether the split loads can be absorbed while waiting
// for writes to go through to the L2 cache. However, even if it does
// have a genuine performance cost, it seems like the least costly way
// to read the bytecode; structuring the bytecode to avoid split loads
// makes it take up substantially more memory, and the less cache that
// is used for the bytecode, the more that can be used for the output
// buffers. (In particular, increasing the bytecode to 2400 lines so
// that it's available at all four of the alignments required of it
// does not gain, because it then becomes so large that the processor
// struggles to keep it in L1 cache - it only just fits, and there
// isn't any way for it to know which parts of the cache are meant to
// stay in L1 and which are meant to leave to L2, so there's a large
// slowdown when it guesses wrong.)
#define INTERPRET_BYTECODE(bc_offset, buf_offset) \
  vmovdqu %ymm2, [%rdx + bc_offset]; \
  vpshufb %ymm0, LINENO_MID_TEMP, %ymm2; \
  vpsubb %ymm0, %ymm0, %ymm2; \
  vmovdqa [OUTPUT_PTR + buf_offset], %ymm0

// The main loop itself consists of sixteen uses of the bytecode
// interpreter, interleaved (to give the reorder buffer maximum
// flexibility) with all the other logic needed in the main loop.
// (Most modern processors can handle 4-6 instructions per clock cycle
// as long as they don't step on each others' toes; thus this loop's
// performance will be limited by the throughput of the L2 cache, with
// all the other work (bytecode interpretation, instruction decoding,
// miscellaneous other instructions, etc.) fitting into the gaps while
// the processor is waiting for the L2 cache to do its work.)

.p2align 5
main_loop:
// %rdx caches BYTECODE_IP's value at the start of the loop
mov %rdx, BYTECODE_IP
INTERPRET_BYTECODE(0, 0)

// %ymm1 caches LINENO_LOW's value at the start of the loop
vmovdqa %ymm1, LINENO_LOW
INTERPRET_BYTECODE(32, 32)

// Add LINENO_LOW_INCR to LINENO_LOW, checking for carry; it carried
// if the sign bit changed from 0 to 1. (vpandn is unintuitive; this
// is ~%ymm1 & LINENO_LOW, not %ymm1 & ~LINENO_LOW like the name
// suggests.)
vpaddq LINENO_LOW, LINENO_LOW_INCR, LINENO_LOW
INTERPRET_BYTECODE(64, 64)

vpandn %ymm3, %ymm1, LINENO_LOW
INTERPRET_BYTECODE(96, 96)

vpsrlq %ymm3, %ymm3, 63
INTERPRET_BYTECODE(128, 128)

// Add the carry to LINENO_MID (doubling it; LINENO_MID counts in
// units of 100 but a LINENO_LOW carry means 200).
vpaddb %ymm3, %ymm3, %ymm3
INTERPRET_BYTECODE(160, 160)

vpaddq LINENO_MID, LINENO_MID, %ymm3
INTERPRET_BYTECODE(192, 192)

vpmaxub LINENO_MID, LINENO_MID_BASE, LINENO_MID
INTERPRET_BYTECODE(224, 224)

// Update LINENO_MID_TEMP with the new value from LINENO_MID; this is
// the point at which the new value takes effect. This is done at the
// exact midpoint of the loop, in order to reduce the errors from
// updating once every 512 bytes as far as possible.
vpaddb LINENO_MID_TEMP, BIASCII_OFFSET, LINENO_MID
INTERPRET_BYTECODE(256, 256)

// Update the output and bytecode instruction pointers. The change to
// the output pointer kicks in immediately, but is cancelled out via
// the use of a negative offset until the end of the loop.
add OUTPUT_PTR, 512
INTERPRET_BYTECODE(288, -224)

add BYTECODE_IP, 512
INTERPRET_BYTECODE(320, -192)

// The change to the bytecode instruction pointer doesn't kick in
// immediately, because it might need to wrap back to the start (this
// can be done by adding BYTECODE_NEG_LEN to it); this is why the
// interpreter has a cached copy of it in %rdx.
lea %rax, [BYTECODE_IP + BYTECODE_NEG_LEN]
INTERPRET_BYTECODE(352, -160)

INTERPRET_BYTECODE(384, -128)
// Some modern processors can optimise `cmp` better if it appears
// immediately before the command that uses the comparison result, so
// a couple of commands have been moved slightly to put the `cmp` next
// to the use of its result. With modern out-of-order processors,
// there is only a marginal advantage to manually interleaving the
// instructions being used, and the `cmp` advantage outweighs that.
cmp BYTECODE_IP, BYTECODE_END

cmovae BYTECODE_IP, %rax
INTERPRET_BYTECODE(416, -96)

INTERPRET_BYTECODE(448, -64)

INTERPRET_BYTECODE(480, -32)
cmp OUTPUT_PTR, OUTPUT_LIMIT
jb main_loop

after_main_loop:
// There are two reasons the main loop might terminate: either there's
// a pipeful of output, or the line number has increased in width
// (forcing the generaion of new bytecode to put more digits in the
// numbers being printed). In the latter case, a) the output may have
// overrun slightly, and OUTPUT_PTR needs to be moved back to
// OUTPUT_LIMIT:
mov OUTPUT_PTR, OUTPUT_LIMIT
// and b) there may be less than a pipeful of output, in which case it
// wouldn't be safe to output it and the swap_buffers call needs to be
// skipped. Calculate the pipe size into %rax, the amount of output
// into %rdx (swap_buffers needs it there anyway), and compare.
lea %rax, [%rip + iovec_base]
sub %rax, BYTECODE_START
neg %eax
mov %rdx, OUTPUT_PTR
and %edx, (2 << 20) - 1
cmp %edx, %eax
jb 1f
call swap_buffers

// If all the lines at this width have been exhausted, move to the
// next width.
1: test YMMS_AT_WIDTH, YMMS_AT_WIDTH
jnz check_lineno_top_carry

cmp LINENO_WIDTHe, 18  // third phase handles at most 18 digits
je fourth_phase

inc LINENO_WIDTHe
vpcmpeqb %ymm0, %ymm0, %ymm0
vpsubb ENDIAN_SHUFFLE, ENDIAN_SHUFFLE, %ymm0

lea GROUPS_OF_15, [GROUPS_OF_15 + GROUPS_OF_15 * 4]
add GROUPS_OF_15, GROUPS_OF_15

add BYTECODE_END, 320

jmp third_phase_per_width_init

// So far, the code has kept LINENO_MID and LINENO_LOW updated, but
// not LINENO_TOP. Because 10 billion lines of FizzBuzz don't normally
// have a length that's divisible by 512 (and indeed, vary in size a
// little because 10 billion isn't divisible by 15), it's possible for
// the 10-billions and higher digits to need to change in the middle
// of a main loop iteration - indeed, even in the middle of a single
// CPU instruction!
//
// It turns out that when discussing the line number registers above,
// I lied a little about the format. The bottom seven bytes of
// LINENO_MID do indeed represent the hundreds to hundred millions
// digits. However, the eighth changes in meaning over the course of
// the program. It does indeed represent the billions digit most of
// the time; but when the line number is getting close to a multiple
// of 10 billion, the billions and hundred-millions digits will always
// be the same as each other (either both 9s or both 0s). When this
// happens, the format changes: the hundred-millions digit of
// LINENO_MID represents *both* the hundred-millions and billions
// digits of the line number, and the top byte then represents the
// ten-billions digit. Because incrementing a number causes a row of
// consecutive 9s to either stay untouched, or all roll over to 0s at
// once, this effectively lets us do maths on more than 8 digits,
// meaning that the normal arithmetic code within the main loop can
// handle the ten-billions digit in addition to the digits below.
//
// Of course, the number printing code also needs to handle the new
// representation, but the number printing is done by a bytecode
// program, which can be made to output some of the digits being
// printed multiple times by repeating "print digit from LINENO_MID"
// commands within it. Those commands are generated from COUNTER_TOP
// anyway, so the program just changes the constant portion of
// COUNTER_TOP (and moves print-digit commands into the top half) in
// order to produce the appropriate bytecode changes.
//
// A similar method is used to handle carries in the hundred-billions,
// trillions, etc. digits.
//
// Incidentally, did you notice the apparent off-by-one in the
// initialisation of LINENO_MID within third_phase_per_width_init? It
// causes the "billions" digit to be initialised to 1 (not 0) when the
// line number width is 11 or higher. That's because the alternate
// representation will be in use during a line number width change (as
// higher powers of 10 are close to multiples of 10 billion), so the
// digit that's represented by that byte of LINENO_MID genuinely is a
// 1 rather than a 0.
check_lineno_top_carry:

// The condition to change line number format is:
// a) The line number is in normal format, and the hundred-millions
//    and billions digits are both 9; or
// b) The line number is in alternate format, and the hundred-millions
//    digit is 0.
// To avoid branchy code in the common case (when no format change is
// needed), REGEN_TRIGGER is used to store the specific values of the
// hundred-millions and billions digits that mean a change is needed,
// formatted as two repeats of billions, hundred-millions, 9, 9 in
// high-decimal (thus, when using normal format, REGEN_TRIGGER is
// high-decimal 99999999, i.e. -1 when interpreted as binary). The 9s
// are because vpshufd doesn't have very good resolution: the millions
// and ten-millions digits get read too, but can simply just be masked
// out. The two repeats are to ensure that both halves of LINENO_MID
// (the even-hundreds-digit and odd-hundreds-digit halves) have the
// correct value while changing (changing the format while half the
// register still ended ...98999999 would produce incorrect output).
vpshufd %xmm0, LINENO_MIDx, 0xED
vpextrq %rax, %xmm0, 0
mov %rdx, 0x0000ffff0000ffff
or %rax, %rdx
cmp %rax, REGEN_TRIGGER
jne calculate_main_loop_iterations

cmp REGEN_TRIGGER, -1
jne switch_to_normal_representation


switch_to_alternate_representation:
// Count the number of 9s at the end of LINENO_TOP. To fix an edge
// case, the top bit of LINENO_TOP is interpreted as a 0, preventing
// a 9 being recognised there (this causes 10**18-1 to increment to
// 10**17 rather than 10**18, but the program immediately exits
// before this can become a problem).
vpextrq %rdx, LINENO_TOPx, 1
mov SPILL, %rdx
shl %rdx, 1
shr %rdx, 1
not %rdx
bsf %rcx, %rdx
and %rcx, -8

// Change the format of LINENO_TOP so that the digit above the
// consecutive 9s becomes a reference to the top byte of LINENO_MID,
// and the 9s themselves references to the hundred-millions digit.
// This is done via a lookup table that specifies how to move the
// bytes around.
.section .rodata
alternate_representation_lookup_table:
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 7, 9, 10, 11, 12, 13, 14, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 7, 9, 10, 11, 12, 13, 14, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 7, 10, 11, 12, 13, 14, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 7, 10, 11, 12, 13, 14, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 7, 11, 12, 13, 14, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 7, 11, 12, 13, 14, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 7, 12, 13, 14, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 7, 12, 13, 14, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 7, 13, 14, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 7, 13, 14, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 6, 7, 14, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 6, 7, 14, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 6, 6, 7, 15
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 6, 6, 7, 15

.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 6, 6, 6, 7
.byte 0, 1, 2, 3, 4, 5, 6, 6
.byte 6, 6, 6, 6, 6, 6, 6, 7
.text

lea %rax, [%rip + alternate_representation_lookup_table]
vpshufb LINENO_TOP, LINENO_TOP, [%rax + 4 * %rcx]

// The top byte of LINENO_MID also needs the appropriate digit of
// LINENO_TOP placed there.
mov %rdx, SPILL
shr %rdx, %cl
vpinsrb LINENO_MIDx, LINENO_MIDx, %edx, 7
vpinsrb LINENO_MIDx, LINENO_MIDx, %edx, 15
vpermq LINENO_MID, LINENO_MID, 0x44

// Finally, REGEN_TRIGGER needs to store the pattern of digits that
// will prompt a shift back to the normal representation (the hundred-
// millions digit must be 0, and the value of the billions digit will
// be predictable).
inc %edx
shl %edx, 24
or %edx, 0xF6FFFF
mov REGEN_TRIGGERe, %edx
shl %rdx, 32
or REGEN_TRIGGER, %rdx
jmp generate_bytecode


switch_to_normal_representation:
// Switching back is fairly easy: LINENO_TOP can almost be converted
// back into its usual format by running the bytecode program stored
// there to remove any unusual references into LINENO_MID, then
// restoring the usual references manually. Running the program will
// unfortunately convert high-decimal to ASCII (or in this case zeroes
// because there's no need to do the subtraction), but that can be
// worked around by taking the bytewise maximum of the converted and
// original LINENO_TOP values (high-decimal is higher than bytecode
// references and much higher than zero).
vpsubb %ymm2, BASCII_OFFSET, LINENO_TOP
vpshufb %ymm0, LINENO_MID, %ymm2
vpmaxub LINENO_TOP, LINENO_TOP, %ymm0

// Manually fix the constant parts of lineno_top to contain their
// usual constant values
.section .rodata
lineno_top_max:
.byte 198, 197, 196, 195, 194, 193, 192, 191
.byte 255, 255, 255, 255, 255, 255, 255, 255
.byte 190, 189, 188, 187, 186, 185, 184, 183
.byte 255, 255, 255, 255, 255, 255, 255, 255
.text
vpminub LINENO_TOP, LINENO_TOP_MAX, LINENO_TOP

// The billions digit of LINENO_MID needs to be set back to 0 (which
// is its true value at this point: the same as the hundred-thousands
// digit, which is also 0).
vpsllq LINENO_MID, LINENO_MID, 8
vpsrlq LINENO_MID, LINENO_MID, 8
vpmaxub LINENO_MID, LINENO_MID_BASE, LINENO_MID

mov REGEN_TRIGGER, -1

jmp generate_bytecode


///// Fourth phase
//
// Ending at 999999999999999999 lines would be a little unsatisfying,
// so here's a routine to write the quintillionth line and exit.
//
// It's a "Buzz", which we can steal from the first phase's constant.

fourth_phase:

mov ARG1e, 1
lea ARG2, [%rip + fizzbuzz_intro + 11]
mov ARG3, 5
mov SYSCALL_NUMBER, __NR_write
syscall
call exit_on_error
xor ARG1e, ARG1e
jmp exit


///// Error handling code
//
// This doesn't run in a normal execution of the program, and isn't
// particularly optimised; I didn't comment it much because it isn't
// very interesting and also is fairly self-explanatory.

write_stderr:
mov ARG1e, 2
mov SYSCALL_NUMBER, __NR_write
syscall
ret

inefficiently_write_as_hex:
push %rax
push %rcx
shr %rax, %cl
and %rax, 0xF
.section .rodata
hexdigits: .ascii "0123456789ABCDEF"
.text
lea %rcx, [%rip + hexdigits]
movzx %rax, byte ptr [%rcx + %rax]
mov [%rip + error_write_buffer], %al
lea ARG2, [%rip + error_write_buffer]
mov ARG3e, 1
call write_stderr
pop %rcx
pop %rax
sub %ecx, 4
jns inefficiently_write_as_hex
ret

exit_on_error:
test SYSCALL_RETURN, SYSCALL_RETURN
js 1f
ret

.section .rodata
error_message_part_1: .ascii "Encountered OS error 0x"
error_message_part_2: .ascii " at RIP 0x"
error_message_part_3: .ascii ", exiting program.\n"
.text

1: push SYSCALL_RETURN
lea ARG2, [%rip + error_message_part_1]
mov ARG3e, 23
call write_stderr
pop SYSCALL_RETURN
neg SYSCALL_RETURN
mov %rcx, 8
call inefficiently_write_as_hex
lea ARG2, [%rip + error_message_part_2]
mov ARG3e, 10
call write_stderr
pop %rax  // find the caller's %rip from the stack
sub %rax, 5  // `call exit_on_error` compiles to 5 bytes
mov %rcx, 60
call inefficiently_write_as_hex
lea ARG2, [%rip + error_message_part_3]
mov ARG3e, 19
call write_stderr
mov ARG1e, 74
// fall through

exit:
mov SYSCALL_NUMBER, __NR_exit_group
syscall
ud2

.section .rodata
cpuid_error_message:
.ascii "Error: your CPUID command does not support command "
.ascii "0x80000006 (AMD-style L2 cache information).\n"
.text
bad_cpuid_error:
lea ARG2, [%rip + cpuid_error_message]
mov ARG3e, 96
call write_stderr
mov ARG1e, 59
jmp exit

.section .rodata
pipe_error_message:
.ascii "This program can only output to a pipe "
.ascii "(try piping into `cat`?)\n"
.text
pipe_error:
lea ARG2, [%rip + pipe_error_message]
mov ARG3e, 64
call write_stderr
mov ARG1e, 73
jmp exit

.section .rodata
pipe_perm_error_message_part_1:
.ascii "Cannot allocate a sufficiently large kernel buffer.\n"
.ascii "Try setting /proc/sys/fs/pipe-max-size to 0x"
pipe_perm_error_message_part_2: .ascii ".\n"
.text
pipe_perm_error:
lea ARG2, [%rip + pipe_perm_error_message_part_1]
mov ARG3e, 96
call write_stderr
mov %rax, PIPE_SIZE
mov %ecx, 28
call inefficiently_write_as_hex
lea ARG2, [%rip + pipe_perm_error_message_part_2]
mov ARG3e, 2
call write_stderr
mov ARG1e, 77
jmp exit

.section .rodata
pipe_size_error_message_part_1:
.ascii "Failed to resize the kernel pipe buffer.\n"
.ascii "Requested size: 0x"
pipe_size_error_message_part_2: .ascii "\nActual size: 0x"
pipe_size_error_message_part_3:
.ascii "\n(If the buffer is too large, this may cause errors;"
.ascii "\nthe program could run too far ahead and overwrite"
.ascii "\nmemory before it had been read from.)\n"
.text
pipe_size_mismatch_error:
push SYSCALL_RETURN
lea ARG2, [%rip + pipe_size_error_message_part_1]
mov ARG3e, 59
call write_stderr
mov %rax, PIPE_SIZE
mov %ecx, 28
call inefficiently_write_as_hex
lea ARG2, [%rip + pipe_size_error_message_part_2]
mov ARG3e, 16
call write_stderr
pop %rax
mov %ecx, 28
call inefficiently_write_as_hex
lea ARG2, [%rip + pipe_size_error_message_part_3]
mov ARG3e, 141
call write_stderr
mov ARG1e, 73
jmp exit

