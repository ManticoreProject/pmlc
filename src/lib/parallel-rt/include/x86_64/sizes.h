/* sizes.h
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Various sizes for the x86_64 (aka AMD64).
 */

#ifndef _SIZES_H_
#define _SIZES_H_

/* log2 of the BIBOP page size */
#define PAGE_BITS	20	/* one-megabyte pages in the global heap */

/* size of VProc local heap */
#ifndef VP_HEAP_SZB
#  define VP_HEAP_SZB		ONE_MEG
#endif

/* sizes for the stack frame used to run Manticore code. See the asm-glue
   file for information about how the stack frame should be setup. */

/* 256 pointer-sized slots for register spills */
#define SPILL_SZB	2048	

/* 48 bytes for callee saves %rbx, %r12-%r15, %rbp */
#define SAVE_AREA	(6*8)	

/* padding added to save area for the PC upon entry from RTS  */
#define PAD_SZB		8	

/* this total value must be on an 8-byte boundary, so a future callq during execution aligns to 16-bytes per ABI. see asm-glue for more info */
#define FRAME_SZB	(SPILL_SZB+SAVE_AREA+PAD_SZB)

#endif /* !_SIZES_H_ */
