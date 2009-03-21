/* heap.h
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 */

#ifndef _HEAP_H_
#define _HEAP_H_

#include "manticore-rt.h"
#include "vproc.h"
#include "atomic-ops.h"

/* size of a heap chunk */
#define HEAP_CHUNK_SZB		((Addr_t)(4*ONE_MEG))

/********** VProc local heaps **********/

/* VP_HEAP_SZB */		/* defined in manticore-rt.h */
#define VP_HEAP_MASK		((Addr_t)(VP_HEAP_SZB-1))
#define VP_HEAP_DATA_SZB	((Addr_t)(VP_HEAP_SZB - sizeof(VProc_t)))

#define MAJOR_GC_THRESHOLD	((Addr_t)(VP_HEAP_DATA_SZB >> 1))

#define ALLOC_BUF_SZB		((Addr_t)(4*ONE_K))	/* slop at end of nursery */
#define MIN_NURSERY_SZB		((Addr_t)(16*ONE_K))	/* minimum nursery size */

/* set the allocation pointer for a vproc */
STATIC_INLINE void SetAllocPtr (VProc_t *vp)
{
    extern Addr_t MaxNurserySzB;
    Addr_t top = (Addr_t)vp + VP_HEAP_SZB;
    Addr_t szB = ROUNDDOWN((top - vp->oldTop) / 2, WORD_SZB);
    if (szB > MaxNurserySzB) szB = MaxNurserySzB;
    vp->nurseryBase = (top - szB);
    vp->allocPtr = vp->nurseryBase + WORD_SZB;
}

STATIC_INLINE Addr_t LimitPtr (VProc_t *vp)
{
    return (Addr_t)vp + VP_HEAP_SZB - ALLOC_BUF_SZB;;
}

static Addr_t SetLimitPtr (VProc_t *vp, Addr_t newLimitPtr)
{
  Value_t oldLimitPtr = AtomicExchangeValue((Value_t*)&(vp->limitPtr), AddrToValue(newLimitPtr));
  return ValueToAddr(oldLimitPtr);
}

/* return true of the given address is within the given vproc heap */
STATIC_INLINE bool inVPHeap (Addr_t heapBase, Addr_t p)
{
    return (heapBase == (p & ~VP_HEAP_MASK));
}


/********** Exported functions **********/

extern void HeapInit (Options_t *opts);
extern void InitVProcHeap (VProc_t *vp);
extern void AllocToSpaceChunk (VProc_t *vp);
extern VProc_t *AllocVProcMemory (int id);

#endif /* !_HEAP_H_ */
