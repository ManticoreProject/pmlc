/* vproc.c
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 */

#include "manticore-rt.h"
#include <stdio.h>
#include <signal.h>
#include <ucontext.h>
#if defined (TARGET_DARWIN)
#  include <sys/sysctl.h>
#endif
#include "os-memory.h"
#include "os-threads.h"
#include "atomic-ops.h"
#include "vproc.h"
#include "heap.h"
#include "gc.h"
#include "options.h"
#include "value.h"
#include "scheduler.h"
#include "inline-log.h"
#include "time.h"
#include "work-stealing-local-deques.h"
#include "work-stealing-deque.h"

typedef struct {	    /* data passed to NewVProc */
    int		id;		/* VProc ID */
    VProcFn_t	initFn;		/* the initial function to run */
    Value_t	initArg;	/* initial argument data for initFn */
    bool        started;        /* has the vproc started running Manticore code? */
} InitData_t;

static void *NewVProc (void *_data);
static void MainVProc (VProc_t *vp, void *arg);
static void IdleVProc (VProc_t *vp, void *arg);
static void SigHandler (int sig, siginfo_t *si, void *_sc);
static int GetNumCPUs ();

static pthread_key_t	VProcInfoKey;

static Barrier_t	InitBarrier;	/* barrier for initialization */

/********** Globals **********/
int			NumHardwareProcs;
int			NumVProcs;
int			NumIdleVProcs;
VProc_t			*VProcs[MAX_NUM_VPROCS];

extern int ASM_VProcSleep;

/*! \brief Items in the ready-queue lists and on the landing pad */
typedef struct struct_queue_item QueueItem_t;
struct struct_queue_item {
    Value_t	fls;	//!< fiber-local storage of thread
    Value_t	k;	//!< fiber (continuation) of thread
    QueueItem_t	*next;	//!< link field
};

/* VProcInit:
 *
 * Initialization for the VProc management system.
 */
void VProcInit (Options_t *opts)
{
    NumHardwareProcs = GetNumCPUs();
    NumIdleVProcs = 0;

  /* get command-line options */
    NumVProcs = ((NumHardwareProcs == 0) ? DFLT_NUM_VPROCS : NumHardwareProcs);
    NumVProcs = GetIntOpt (opts, "-p", NumVProcs);
    if ((NumHardwareProcs > 0) && (NumVProcs > NumHardwareProcs))
	Warning ("%d processors requested on a %d processor machine\n",
	    NumVProcs, NumHardwareProcs);

#ifndef NDEBUG
    SayDebug("%d/%d processors allocated to vprocs\n", NumVProcs, NumHardwareProcs);
#endif

#ifdef ENABLE_LOGGING
  /* initialize the log file */
    const char *logFile = GetStringOpt(opts, "-log", DFLT_LOG_FILE);
    InitLogFile (logFile, NumVProcs, NumHardwareProcs);
#endif

    if (pthread_key_create (&VProcInfoKey, 0) != 0) {
	Die ("unable to create VProcInfoKey");
    }

  /* Initialize the work stealing scheduler-local data */
    M_InitWorkGroupList ();

  /* Initialize vprocs */
    BarrierInit (&InitBarrier, NumVProcs+1);

    InitData_t *initData = NEWVEC(InitData_t, NumVProcs);
    initData[0].id = 0;
    initData[0].initFn = MainVProc;
    initData[0].initArg = M_UNIT;
    for (int i = 1;  i < NumVProcs;  i++) {
	initData[i].id = i;
	initData[i].initFn = IdleVProc;
	initData[i].initArg = M_UNIT;
    }

    for (int i = 0;  i < NumVProcs;  i++) {
	OSThread_t pid;
	if (! ThreadCreate (&pid, NewVProc, &(initData[i])))
	    Die ("Unable to start vproc %d\n", i);
    }

    BarrierWait (&InitBarrier);

    FREE (initData);

} /* end of VProcInit */


/* NewVProc:
 *
 * Create the data structures and underlying system thread to
 * implement a vproc.  This code is run in the OS thread that hosts
 * the vproc.
 */
void *NewVProc (void *arg)
{
    InitData_t	*initData = (InitData_t *)arg;
    struct sigaction	sa;

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] NewVProc: initializing ...\n", initData->id);
#endif

#ifdef HAVE_PTHREAD_SETAFFINITY_NP 
    cpu_set_t	cpus;
    CPU_ZERO(&cpus);
    CPU_SET(initData->id, &cpus);
    if (pthread_setaffinity_np (pthread_self(), sizeof(cpu_set_t), &cpus) == -1) {
	Warning("[%2d] unable to set affinity\n", initData->id);
    }
#endif

    VProc_t* vproc = AllocVProcMemory (initData->id);
    if (vproc == 0) {
	Die ("unable to allocate memory for vproc %d\n", initData->id);
    }
    VProcs[initData->id] = vproc;

  /* initialize the vproc structure */
    vproc->id = initData->id;
    vproc->hostID = pthread_self();

    vproc->oldTop = VProcHeap(vproc);
    InitVProcHeap (vproc);

    vproc->atomic = M_TRUE;
    vproc->sigPending = M_FALSE;
    vproc->sleeping = M_FALSE;
    vproc->actionStk = M_NIL;
    vproc->schedCont = M_NIL;
    vproc->dummyK = M_NIL;
    vproc->wakeupCont = M_NIL;
    vproc->rdyQHd = M_NIL;
    vproc->rdyQTl = M_NIL;
    vproc->landingPad = M_NIL;
    vproc->stdArg = M_UNIT;
    vproc->stdEnvPtr = M_UNIT;
    vproc->stdCont = M_NIL;
    vproc->stdExnCont = M_UNIT;
    SetLimitPtr(vproc, LimitPtr(vproc));
    SetAllocPtr (vproc);
    vproc->currentFLS = M_NIL;

#ifdef ENABLE_LOGGING
    InitLog (vproc);
#endif

  /* store a pointer to the VProc info as thread-specific data */
    pthread_setspecific (VProcInfoKey, vproc);

  /* Note that initData gets freed in VProcInit after the barrier, so we need
   * to cache the contents locally.
   */
    VProcFn_t initFn = initData->initFn;
    Value_t initArg = initData->initArg;

  /* Wait until all vprocs have been initialized */
    BarrierWait (&InitBarrier);

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] NewVProc: run initFn\n", vproc->id);
#endif

  /* run the initial vproc function */
    initFn (vproc, initArg);

    Die ("should never get here!");

    return 0;

} /* VProcCreate */


/* MainVProc:
 *
 * The main vproc is responsible for running the Manticore code.  The
 * argument is the address of the initial entry-point in Manticore program.
 */ 
static void MainVProc (VProc_t *vp, void *arg)
{
    extern int mantEntry;		/* the entry-point of the Manticore code */

    LogVProcStartMain (vp);

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] MainVProc starting\n", vp->id);
#endif

    vp->sleeping = false;

    FunClosure_t fn = {.cp = PtrToValue(&mantEntry), .ep = M_UNIT};
    Value_t resV = ApplyFun (vp, PtrToValue(&fn), PtrToValue(arg));

#ifndef NDEBUG
    Say("res = ");
    SayValue (resV);
    Say("\n");
#endif

    LogVProcExitMain (vp);

#ifdef ENABLE_LOGGING
    FinishLog ();
#endif

    exit (0);

}

/*! \brief return a pointer to the VProc that the caller is running on.
 *  \return the VProc that the caller is running on.
 */
VProc_t *VProcSelf ()
{
    return (VProc_t *)pthread_getspecific (VProcInfoKey);

} /* VProcSelf */

/*! \brief wake the vproc.
 *  \param vp the vproc to wake
 */
void VProcWake (VProc_t *vp)
{
    assert (vp != VProcSelf());
    CondSignal (&(vp->wait));
}

/*! \brief place a signal (fiber + fiber-local storage) on the landing pad of the remote vproc.
 *  \param self the host vproc.
 *  \param vp the destination vproc.
 *  \param k the fiber
 *  \param fls the fiber-local storage
 */
void VProcSendSignal (VProc_t *self, VProc_t *vp, Value_t fls, Value_t k)
{
    Value_t landingPadOrig, landingPadNew, x;

    Value_t dummyFLS = GlobalAllocNonUniform (self, 4, INT(-1), PTR(M_NONE), INT(0), PTR(M_NIL));

    do {
	landingPadOrig = vp->landingPad;
	landingPadNew = GlobalAllocUniform (self, 3, dummyFLS, k, landingPadOrig);
	x = CompareAndSwapValue(&(vp->landingPad), landingPadOrig, landingPadNew);
    } while (x != landingPadOrig);

    if (vp->sleeping == M_TRUE)
	VProcWake(vp);

}

/*! \brief set a vproc's limit pointer to zero
 */
void VProcZeroLimitPtr (VProc_t *vp)
{
  SetLimitPtr(vp, 0);
}

/*! \brief interrupt a remote vproc to take part in a global collection.
 *  \param self the host vproc.
 *  \param vp the remote vproc.
 */
void VProcGlobalGCInterrupt (VProc_t *self, VProc_t *vp)
{
    vp->globalGCPending = true;
    assert(vp->currentFLS != M_NIL);
    VProcSendSignal(self, vp, vp->currentFLS, vp->dummyK);
    VProcZeroLimitPtr(vp);
}

/*! \brief send a preemption to a remote vproc.
 *  \param vp the remote vproc to preempt.
 */
void VProcPreempt (VProc_t *self, VProc_t *vp)
{
#ifndef NDEBUG
    if (DebugFlg)
	if (self == 0)
	  SayDebug("Timer interrupt on vproc %d from %d.\n", self->id, vp->id);
	else
	  SayDebug("[%2d] Signaling vproc %d.\n", self->id, vp->id);
#endif

    VProcZeroLimitPtr(vp);
}

/*! \brief put the vproc to sleep until a signal arrives
 *  \param vp the vproc that is being put to sleep.
 */
void VProcSleep (VProc_t *vp)
{
    assert (vp == VProcSelf());

    LogVProcSleep (vp);

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] VProcSleep called\n", vp->id);
#endif

    MutexLock(&(vp->lock));
	AtomicWriteValue (&(vp->sleeping), M_TRUE);
	while (vp->landingPad == M_NIL)
	    CondWait (&(vp->wait), &(vp->lock));
	AtomicWriteValue (&(vp->sleeping), M_FALSE);
    MutexUnlock(&(vp->lock));

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] VProcSleep exiting\n", vp->id);
#endif

}

/* IdleVProc:
 */
static void IdleVProc (VProc_t *vp, void *arg)
{
    LogVProcStartIdle (vp);

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] IdleVProc starting\n", vp->id);
#endif

    VProcSleep(vp);
  /* Activate scheduling code on the vproc. */
    Value_t envP = vp->schedCont;
    Addr_t codeP = ValueToAddr(ValueToCont(envP)->cp);
    RunManticore (vp, codeP, vp->dummyK, envP);

#ifndef NDEBUG
    if (DebugFlg)
	SayDebug("[%2d] return from RunManticore in idle vproc\n", vp->id);
#endif
    exit (0);

} /* end of IdleVProc */

static int GetNumCPUs ()
{
#if defined(HAVE__PROC_CPUINFO)
  /* Get the number of hardware processors on systems that have /proc/cpuinfo */
    FILE *cpuinfo = fopen("/proc/cpuinfo", "r");
    char buf[1024];
    if (cpuinfo != NULL) {
	int n = 0;
	while (fgets(buf, sizeof(buf), cpuinfo) != 0) {
	    int id;
	    if (sscanf(buf, "processor : %d", &id) == 1)
		n++;
	}
	fclose (cpuinfo);
	return n;
    }
    else {
	Warning("unable to determine the number of processors\n");
	return 0;
    }
#elif defined(TARGET_DARWIN)
    int		numCPUs;
    size_t	len = sizeof(int);
    if (sysctlbyname("hw.activecpu", &numCPUs, &len, 0, 0) < 0) {
	Warning("unable to determine the number of processors\n");
	return 0;
    }
    else
	return numCPUs;
#else
    return 0;
#endif

} /* end of GetNumCPUs */


/***** Exported VProc operations *****
 *
 * The following functions are exported to the BOM runtime code.
 */

/*! \brief return the number of virtual processos in the system.
 */
int GetNumVProcs ()
{
    return NumVProcs;
}

/*! \brief return a list of the vprocs in the system.
 *  \param self the host vproc
 *
 * This function returns a list of the virtual processors in the system.  The vproc
 * values are wrapped to avoid confusing the GC.
 */
Value_t ListVProcs (VProc_t *self)
{
    Value_t	l = M_NIL;

    for (int i = NumVProcs-1;  i >= 0;  i--) {
	Value_t vp = WrapWord (self, (Word_t)(VProcs[i]));
	l = Cons(self, vp, l);
    }

    return l;

}

/*! \brief return a pointer to the nth vproc
 *  \param n vproc id
 */
VProc_t* GetNthVProc (int n)
{
    assert(n >= 0 && n < NumVProcs);
    return VProcs[n];
}

/*! \brief create a fiber that puts the vproc to sleep
 *  \param self the calling vproc
 *  \return fiber that when run puts the vproc to sleep
 */
Value_t SleepCont (VProc_t *self)
{
    return AllocUniform(self, 1, PtrToValue(&ASM_VProcSleep));
}

