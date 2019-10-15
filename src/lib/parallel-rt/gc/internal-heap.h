/* internal-heap.h
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Internal heap data structures.
 */

#ifndef _INTERNAL_HEAP_H_
#define _INTERNAL_HEAP_H_

#include "manticore-rt.h"
#include "heap.h"
#include "statepoints.h"

typedef enum {
    FREE_CHUNK,			/*!< chunk that is available for allocation */
    TO_SP_CHUNK,		/*!< to-space chunk in the global heap */
    FROM_SP_CHUNK,		/*!< from-space chunk in the global heap */
    VPROC_CHUNK_TAG,		/*!< low four bits of VProc chunk (see #VPROC_CHUNK) */
    UNMAPPED_CHUNK		/*!< special status used for the dummy chunk that
				 *   represents unmapped regions of the memory space.
				 */
} Status_t;

#define VPROC_CHUNK(id)		((Status_t)((id) << 4) | VPROC_CHUNK_TAG)
#define IS_VPROC_CHUNK(sts)	(((sts)&0xF) == VPROC_CHUNK_TAG)

struct struct_chunk {
    void *  allocBase;  /*!< base address (unaligned!) of original allocation */
    Addr_t	baseAddr;	/*!< chunk base address */
    Addr_t	szB;		/*!< chunk size in bytes */
    Addr_t	usedTop;	/*!< [baseAddr..usedTop) is the part of the
				 *   chunk in use
				 */
    MemChunk_t	*next;		/*!< link field */
    Status_t	sts;		/*!< current status of chunk */
    int		where;		/*!< the node of the vproc that allocated
				 *   this chunk.
				 */
    Addr_t      scanProgress;  /*!< used only for the current alloc chunk
                     to track if it has been partially scanned */
};

typedef struct {
    Mutex_t lock;      //! lock to protect per-node data
    Cond_t   scanWait;    //! used to wait for a chunk to scan
    volatile int numWaiting;   //! number of vprocs waiting for a chunk to scan
    volatile bool completed;       //! no chunks remain
    MemChunk_t *scannedTo;   //! Chunks that have been scanned during global GC
    MemChunk_t *unscannedTo; //! Allocated chunks not yet scanned
    MemChunk_t *fromSpace;   //! Prior to-space chunks that will become free at
      //! the end of global GC
    MemChunk_t *freeChunks;  //!< free chunks allocated on this node
} NodeHeap_t;


// NOTE: we are not using an enum here because it's unclear where in the stack
// info struct the age would be if it's not 8 bytes wide.
// We need hand-written ASM that correctly accesses this field.
typedef uint64_t Age_t;

// ASM & LLVM rely on these values not changing!!
#define AGE_Minor 0
#define AGE_Major 1
#define AGE_Global 2


#if defined(RESIZESTACK)

  // in terms of number of bytes
  #define MAX_STACK_CACHE_SZ      (2 * (dfltStackSz / ONE_K) * ONE_MEG)
  #define MAX_SEG_SIZE_IN_CACHE   dfltStackSz

  // in terms of number of segments, since the size varies
  #define MAX_ALLOC_SINCE_GC   (1 + (256 * ONE_MEG) / dfltStackSz)
  #define FIRST_FIT_MAX_CHK    (2)

  #define RESIZED_SEG_LIMIT    (32 * ONE_MEG)

#else

  // both in terms of bytes, for other stack strategies that use large-object
  // allocation (segmented and contiguous).
  #define MAX_STACK_CACHE_SZ      (2 * (dfltStackSz / ONE_K) * ONE_MEG)
  #define MAX_SEG_SIZE_IN_CACHE   dfltStackSz

  #define MAX_ALLOC_SINCE_GC      (4096ULL * ONE_MEG)

#endif

// we have some hand-written ASM that accesses this struct
// assuming all fields are 8 bytes wide.
#define ALIGN_8  __attribute__ ((aligned (8)))

typedef struct {
  StackInfo_t* top;
  char padding[128-sizeof(StackInfo_t*)];
} PaddedStackInfoPtr_t;

extern Mutex_t GlobStackMutex;

// outside globGC, requires GlobStackMutex
// inside globGC, leader vproc exclusive.
extern StackInfo_t* GlobAllocdList;

// outside globGC, each vproc has exlusive access to its own element.
// inside globGC, leader vproc has exlusive access to add elements.
extern PaddedStackInfoPtr_t *GlobFreeStacks;

struct struct_stackinfo {
    // these fields are only used by segmented stacks.
    void* currentSP             ALIGN_8;
    StackInfo_t* prevSegment    ALIGN_8;

    // fields used by all stacks
    StackInfo_t* next   ALIGN_8;  // link to next stack in the free/allocated list
    void* initialSP     ALIGN_8;
    void* stkLimit      ALIGN_8;
    StackInfo_t* prev   ALIGN_8;  // link to previous stack in the list
    void* deepestScan   ALIGN_8;  // unscanned <=> deepestScan == ptr to its own StackInfo_t
    Age_t age           ALIGN_8;
    VProc_t* owner      ALIGN_8;
    uint64_t canCopy    ALIGN_8; // if true, indicates that it's safe to copy frames out of this segment
    size_t guardSz      ALIGN_8;
    size_t usableSpace  ALIGN_8;
    uint8_t* memAlloc   ALIGN_8;
    Mutex_t gcLock      ALIGN_8;
  #ifndef NO_GC_STATS
    uint64_t totalSz   ALIGN_8;   // in bytes
  #endif
};



/********** Global heap **********/

/* default global-heap-size constants */
#ifndef NDEBUG
#  define BASE_GLOBAL_HEAP_SZB	HEAP_CHUNK_SZB
#  define PER_VPROC_HEAP_SZB	HEAP_CHUNK_SZB
#else
#  define BASE_GLOBAL_HEAP_SZB	(ONE_K * ONE_MEG)
#  define PER_VPROC_HEAP_SZB	(32 * ONE_MEG)
#endif

extern Mutex_t		HeapLock;	/*!< lock for protecting heap data structures */
extern Addr_t		GlobalVM;	/*!< amount of memory allocated to Global heap
					 *  (including free chunks). */
extern Addr_t		FreeVM;		/*!< amount of free memory in free list */
extern Addr_t		ToSpaceSz;	/*!< amount of memory being used for to-space */
extern Addr_t		ToSpaceLimit;	/*!< if ToSpaceSz exceeds this value, then do a
					 * global GC */
extern Addr_t		TotalVM;	/*!< total memory used by heap (including vproc
					 * local heaps) */
extern NodeHeap_t   *NodeHeaps; /*!< list of per-node heap information */

extern Addr_t		HeapScaleNum;
extern Addr_t		HeapScaleDenom;
extern Addr_t		BaseHeapSzB;
extern Addr_t		PerVprocHeapSzb;
extern size_t		dfltStackSz;

extern statepoint_table_t* SPTbl; // the statepoint table

extern void UpdateBIBOP (MemChunk_t *chunk);

extern void FreeChunk (MemChunk_t *);

/* GC routines */
extern void InitGlobalGC ();
extern void StartGlobalGC (VProc_t *self, Value_t **roots);
extern MemChunk_t *PushToSpaceChunks (VProc_t *vp, MemChunk_t *scanChunk, bool inGlobal);

extern StackInfo_t* FreeStacks(VProc_t *vp, StackInfo_t*, Age_t epoch, bool GlobalGCLeader);
extern StackInfo_t* FreeOneStack(VProc_t *vp, StackInfo_t* allocd, bool GlobalGC);
extern void RemoveFromAllocList(VProc_t *vp, StackInfo_t* allocd);

extern void ScanStackMinor (
    void* origStkPtr,
    StackInfo_t* stkInfo,
    Addr_t nurseryBase,
    Addr_t allocSzB,
    Word_t **nextW);

extern void ScanStackMajor (
    void* origStkPtr,
    StackInfo_t* stkInfo,
    Addr_t heapBase,
    VProc_t *vp);

extern void ScanStackGlobal (
    void* origStkPtr,
    StackInfo_t* stkInfo,
    VProc_t* vp);



/* GC debugging support */
#ifndef NDEBUG
typedef enum {
    GC_DEBUG_ALL	= 4,		/* all debug messages (including promotions) */
    GC_DEBUG_MINOR	= 3,
    GC_DEBUG_MAJOR	= 2,
    GC_DEBUG_GLOBAL	= 1,
    GC_DEBUG_NONE	= 0
} GCDebugLevel_t;

extern GCDebugLevel_t	GCDebug;	//!\brief Flag that controls GC debugging output
extern GCDebugLevel_t	HeapCheck;	//!\brief Flag that controls heap checking

#define GC_DEBUG_DEFAULT "major"	/* default level */
#define HEAP_DEBUG_DEFAULT "global"	/* default level */
#endif

#endif /* !_INTERNAL_HEAP_H_ */
