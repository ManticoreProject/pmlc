(* read-set.pml
 *
 * COPYRIGHT (c) 2014 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Chronologically ordered read sets for NoRec
 *)

 

structure FFReadSet = 
struct

#define NEXT 3
#define READ_VAL 2
#define NEXTK 6
#define KPOINTER 5
#define HEAD 0
#define TAIL 1
#define LASTK 2
#define NUMK 3

#define START_TIMER let vp : vproc = host_vproc do ccall GenTimerStart(vp)
#define STOP_TIMER let vp : vproc = host_vproc do ccall GenTimerStop(vp)
   
    _primcode(

        typedef item = NoRecOrderedReadSet.item;

        extern void M_Print_Long2(void *, void *, void *);
        extern void M_IncCounter(void *, int , long);
        extern int M_PolyEq(void*, void*);

    	typedef read_set = ![item,      (*0: first element of the read set*) 
    						 item, 	    (*1: last element of the read set*)
    						 item, 	    (*2: last checkpoint (element on short path)*)
    						 int];	    (*3: number of checkpoints in read set*)

        typedef mutWithK = ![any,    (*0: tag*)
                             any,    (*1: tvar*)
                             any,    (*2: contents read*)
                             item,   (*3: next pointer*)
                             any,    (*4: write set*)
                             any,    (*5: continuation*)
                             item];  (*6: next checkpoint pointer*)

        typedef stamp = VClock.stamp;
        typedef tvar = FullAbortSTM.tvar; (*contents, lock, version stamp*)

        define inline @get-stamp(/exh:exh) : stamp = 
            fun stampLoop() : long = 
                let current : long = VClock.@get(/exh)
                let lastBit : long = I64AndB(current, 1:long)
                if I64Eq(lastBit, 0:long)
                then return(current)
                else do Pause() apply stampLoop()
            let stamp : stamp = apply stampLoop()
            return(stamp)
        ;

    	define @new() : read_set = 
            let dummyTRef : ![any,long,long] = alloc(enum(0), 0:long, 0:long)
            let dummy : item =  NoRecOrderedReadSet.WithoutK(dummyTRef, enum(0), NoRecOrderedReadSet.NilItem)
    		let rs : read_set = alloc(dummy, dummy, NoRecOrderedReadSet.NilItem, 0)
    		return(rs)
    	;

	   define inline @eager-abort(readSet : read_set, checkpoint : item, startStamp : ![stamp, int, int, long], 
				   count:int, revalidate : fun(item, item, int, int / -> ), pos : int / exh:exh) : () = 
            do #1(startStamp) := I32Add(#1(startStamp), 1)
            case checkpoint 
               of NoRecOrderedReadSet.NilItem => (*no checkpoint available*)
		    do Logging.@log-eager-full-abort()
                    (*<FF>*)
                    do FLS.@set-key(FF_KEY, readSet / exh)
                    (*</FF>*)
                    let abortK : cont() = FLS.@get-key(ABORT_KEY / exh) 
                    throw abortK()
                | NoRecOrderedReadSet.WithK(tv:tvar, _:any, next:item, ws:item, abortK:cont(any),_:item) => 
		    do Logging.@log-eager-partial-abort(pos)
                    let casted : ![any, any, any, item] = (![any, any, any, item]) checkpoint
                    do #NEXT(casted) := NoRecOrderedReadSet.NilItem  (*split valid and invalid portions*)
                    fun getLoop() : any = 
                        let v : any = #0(tv)
                        let t : long = VClock.@get(/exh)
                        if I64Eq(t, #0(startStamp))
                        then return(v)
                        else
                            let currentTime : stamp = @get-stamp(/exh)
                            do #0(startStamp) := currentTime
                            do apply revalidate(#HEAD(readSet), NoRecOrderedReadSet.NilItem, 0, 0)
                            apply getLoop()
                    let current : any = apply getLoop()
                    do #READ_VAL(casted) := current
                    let newRS : read_set = alloc(#HEAD(readSet), checkpoint, checkpoint, count)
                    do FLS.@set-key(READ_SET, newRS / exh)
                    do FLS.@set-key(WRITE_SET, ws / exh)
                    (*<FF>*)
                    do #HEAD(readSet) := NoRecOrderedReadSet.NilItem (*we don't need this field anymore*)
                    do FLS.@set-key(FF_KEY, readSet / exh) (*try and use this portion of the read set on our second run through*)
                    let vp : vproc = host_vproc
                    (*</FF>*)
                    let captureFreq : int = FLS.@get-counter2()
                    do FLS.@set-counter(captureFreq)
                    BUMP_PABORT
                    throw abortK(current)
            end
        ;

        define @eager-validate(readSet : read_set, startStamp:![stamp, int, int, long] / exh:exh) : () =  
            do Logging.@log-start-validate()
            fun eagerValidateLoopABCD(rs : item, abortInfo : item, count:int, pos:int) : () =
                case rs 
                   of NoRecOrderedReadSet.NilItem => (*finished validating*)
                        let currentTime : stamp = VClock.@get(/exh)
                        if I64Eq(currentTime, #0(startStamp))
                        then do Logging.@log-ts-extension() return() (*no one committed while validating*)
                        else  (*someone else committed, so revalidate*)
                            let currentTime : stamp = @get-stamp(/exh)
                            do #0(startStamp) := currentTime
                            apply eagerValidateLoopABCD(#HEAD(readSet), NoRecOrderedReadSet.NilItem, 0, 0)
                    |  NoRecOrderedReadSet.WithoutK(tv:tvar, x:any, next:item) =>
                        if Equal(#0(tv), x)
                    then apply eagerValidateLoopABCD(next, abortInfo, count, I32Add(pos, 1))
                        else @eager-abort(readSet, abortInfo, startStamp, count, eagerValidateLoopABCD, pos / exh)
                    | NoRecOrderedReadSet.WithK(tv:tvar,x:any,next:item,ws:item,abortK:any,_:item) =>
                        if Equal(#0(tv), x)
                        then 
                            if Equal(abortK, enum(0))
                            then apply eagerValidateLoopABCD(next, abortInfo, count, I32Add(pos, 1))            (*update checkpoint*)
                            else apply eagerValidateLoopABCD(next, rs, I32Add(count, 1), I32Add(pos, 1))
                        else
                            if Equal(abortK, enum(0))
                            then @eager-abort(readSet, abortInfo, startStamp, count, eagerValidateLoopABCD, pos / exh)
                            else @eager-abort(readSet, rs, startStamp, count, eagerValidateLoopABCD, pos / exh)
                end
            let currentTime : stamp = @get-stamp(/exh)
            do #0(startStamp) := currentTime
            apply eagerValidateLoopABCD(#HEAD(readSet), NoRecOrderedReadSet.NilItem, 0, 0)
        ;

        define inline @commit-abort(readSet : read_set, checkpoint : item, startStamp : ![stamp, int, int, long], count:int, revalidate : fun(item, item, int, int / -> ), pos:int / exh:exh) : () = 
            do #1(startStamp) := I32Add(#1(startStamp), 1)
            case checkpoint 
               of NoRecOrderedReadSet.NilItem => (*no checkpoint available*)
		    do Logging.@log-commit-full-abort()
                    (*<FF>*)
                    do FLS.@set-key(FF_KEY, readSet / exh)
                    (*</FF>*)
                    let abortK : cont() = FLS.@get-key(ABORT_KEY / exh) 
                    throw abortK()
                | NoRecOrderedReadSet.WithK(tv:tvar, _:any, next:item, ws:item, abortK:cont(any),_:item) => 
		            do Logging.@log-commit-partial-abort(0)
                    let casted : ![any, any, any, item] = (![any, any, any, item]) checkpoint
                    do #NEXT(casted) := NoRecOrderedReadSet.NilItem  (*split valid and invalid portions*)
                    fun getLoop() : any = 
                        let v : any = #0(tv)
                        let t : long = VClock.@get(/exh)
                        if I64Eq(t, #0(startStamp))
                        then return(v)
                        else
                            let currentTime : stamp = @get-stamp(/exh)
                            do #0(startStamp) := currentTime
                            do apply revalidate(#HEAD(readSet), NoRecOrderedReadSet.NilItem, 0, 0)
                            apply getLoop()
                    let current : any = apply getLoop()
                    do #READ_VAL(casted) := current
                    let newRS : read_set = alloc(#HEAD(readSet), checkpoint, checkpoint, count)
                    do FLS.@set-key(READ_SET, newRS / exh)
                    do FLS.@set-key(WRITE_SET, ws / exh)
                    (*<FF>*)
                    do #NUMK(readSet) := I32Sub(#NUMK(readSet), count)
                    do #HEAD(readSet) := NoRecOrderedReadSet.NilItem (*we don't need this field anymore*)
                    do FLS.@set-key(FF_KEY, readSet / exh) (*try and use this portion of the read set on our second run through*)
                    let vp : vproc = host_vproc
                    (*</FF>*)
                    let captureFreq : int = FLS.@get-counter2()
                    do FLS.@set-counter(captureFreq)
                    BUMP_PABORT
                    throw abortK(current)
            end
        ;

        define @commit-validate(readSet : read_set, startStamp:![stamp, int, int, long] / exh:exh) : () = 
            do Logging.@log-start-validate()
            fun validateLoopABCD(rs : item, abortInfo : item, count:int, i:int) : () =
                case rs 
                   of NoRecOrderedReadSet.NilItem => (*finished validating*)
                        let currentTime : stamp = VClock.@get(/exh)
                        if I64Eq(currentTime, #0(startStamp))
                        then return() (*no one committed while validating*)
                        else  (*someone else committed, so revalidate*)
                            let currentTime : stamp = @get-stamp(/exh)
                            do #0(startStamp) := currentTime
                            apply validateLoopABCD(#HEAD(readSet), NoRecOrderedReadSet.NilItem, 0, I32Add(i, 1))
                    |  NoRecOrderedReadSet.WithoutK(tv:tvar, x:any, next:item) =>
                        if Equal(#0(tv), x)
                        then apply validateLoopABCD(next, abortInfo, count, I32Add(i, 1))
                        else @commit-abort(readSet, abortInfo, startStamp, count, validateLoopABCD, i / exh)
                    | NoRecOrderedReadSet.WithK(tv:tvar,x:any,next:item,ws:item,abortK:any,_:item) =>
                        if Equal(#0(tv), x)
                        then 
                            if Equal(abortK, enum(0))
                            then apply validateLoopABCD(next, abortInfo, count, I32Add(i, 1))            (*update checkpoint*)
                            else apply validateLoopABCD(next, rs, I32Add(count, 1), I32Add(i, 1))
                        else
                            if Equal(abortK, enum(0))
                            then @commit-abort(readSet, abortInfo, startStamp, count, validateLoopABCD, i / exh)
                            else @commit-abort(readSet, rs, startStamp, count, validateLoopABCD, i / exh)
                end
            let currentTime : stamp = @get-stamp(/exh)
            do #0(startStamp) := currentTime
            apply validateLoopABCD(#HEAD(readSet), NoRecOrderedReadSet.NilItem, 0, 0)
        ;

        define @ff-finish(readSet : read_set, checkpoint : item, i:int / exh:exh) : () =
            case checkpoint 
               of NoRecOrderedReadSet.WithK(tv:tvar,x:any,_:item,ws:item,k:cont(any),next:item) => 
                    let casted : mutWithK = (mutWithK) checkpoint
                    do #NEXT(casted) := NoRecOrderedReadSet.NilItem
                    let newRS : read_set = alloc(#0(readSet), checkpoint, checkpoint, i)
                    do FLS.@set-key(READ_SET, newRS / exh)
                    do FLS.@set-key(WRITE_SET, ws / exh)
                    let vp : vproc = host_vproc
                    BUMP_KCOUNT
		    do Logging.@log-fast-forward()
                    throw k(x)
                | _ => do ccall M_Print("Impossible: ff-finish\n") throw exh(Fail(@"Impossible: ff-finish\n"))
            end
        ;

        define @ff-validate(readSet : read_set, oldRS : item, myStamp : ![long,int,int,long] / exh:exh) : () = 
            fun ffLoop(rs:item, i:int, checkpoint : item) : () = 
                case rs
                   of NoRecOrderedReadSet.NilItem => @ff-finish(readSet, checkpoint, i / exh)
                    |  NoRecOrderedReadSet.WithoutK(tv:tvar, x:any, next:item) => 
                        if Equal(#0(tv), x)
                        then apply ffLoop(next, i, checkpoint)
                        else @ff-finish(readSet, checkpoint, i / exh)
                    | NoRecOrderedReadSet.WithK(tv:tvar,x:any,next:item,ws:item,k:cont(any),_:item) => 
                        if Equal(#0(tv), x)
                        then
                            if Equal(k, enum(0))
                            then apply ffLoop(next, i, checkpoint)
                            else apply ffLoop(next, I32Add(i, 1), rs)
                        else 
                            if Equal(k, enum(0))
                            then @ff-finish(readSet, checkpoint, i / exh)
                            else
                                let casted : mutWithK = (mutWithK) rs
                                do #NEXT(casted) := NoRecOrderedReadSet.NilItem
                                let newRS : read_set = alloc(#0(readSet), rs, rs, I32Add(i, 1))
                                do FLS.@set-key(READ_SET, newRS / exh)
                                do FLS.@set-key(WRITE_SET, ws / exh)
                                let vp : vproc = host_vproc
                                fun getLoop() : any = 
                                    let v : any = #0(tv)
                                    let t : long = VClock.@get(/exh)
                                    if I64Eq(t, #0(myStamp))
                                    then return(v)
                                    else
                                        do @eager-validate(newRS, myStamp / exh)
                                        apply getLoop()
                                let current : any = apply getLoop()
                                throw k(current)
                end
            apply ffLoop(oldRS, #NUMK(readSet), oldRS)
        ;

        define @fast-forward(readSet : read_set, writeSet : item, tv:tvar, retK:cont(any), myStamp : ![long, int, int, long] / exh:exh) : () = 
            let ffInfo : read_set = FLS.@get-key(FF_KEY / exh)
            if Equal(ffInfo, enum(0))
            then return()
            else (*we should only allocate the checkRS closure if we are going to actually use it*)
                fun checkRS(rs:item, i:int) : () = 
                    case rs 
                       of NoRecOrderedReadSet.NilItem =>  return()
                        | NoRecOrderedReadSet.WithK(tv':tvar,_:any,_:item,ws:item,k:cont(any),next:item) => 
                            if Equal(tv, tv')
                            then (*tvars are equal*)
                                let res : int = ccall M_PolyEq(k, retK)
                                if I32Eq(res, 1)
                                then (*continuations are equal*)
                                    if Equal(ws, writeSet)
                                    then (*continuations, write sets, and tvars are equal, fast forward...*)
                                        do FLS.@set-key(FF_KEY, enum(0) / exh)  (*null out fast forward info*)
                                        (*hook the two read sets together*)
                                        let ffFirstK : mutWithK = (mutWithK) rs
                                        let vp : vproc = host_vproc
                                        let rememberSet : any = vpload(REMEMBER_SET, vp)
                                        let newRemSet : [mutWithK, int, long, any] = alloc(ffFirstK, NEXTK, #3(myStamp), rememberSet)
                                        do vpstore(REMEMBER_SET, vp, newRemSet)
                                        do #NEXTK(ffFirstK) := #LASTK(readSet) 
                                        let currentLast : item = #TAIL(readSet)
                                        let currentLast : mutWithK = (mutWithK) currentLast
                                        do #NEXT(currentLast) := rs
                                        @ff-validate(readSet, rs, myStamp / exh)
                                    else apply checkRS(next, I32Add(i, 1))
                                else apply checkRS(next, I32Add(i, 1))
                            else apply checkRS(next, I32Add(i, 1))
                        | _ => 
                            let casted : [any] = ([any]) rs
                            do ccall M_Print_Long("checkRS: impossible, tag is %lu\n\n", #0(casted)) 
                            throw exh(Fail("checkRS: impossible\n"))
                    end
                INC_FF(1:long)
                apply checkRS(#LASTK(ffInfo), 1)
        ;

        define inline @filterRS(readSet : read_set, stamp : ![long, int, int, long] / exh : exh) : () = 
            let vp : vproc = host_vproc
            fun dropKs(l:item, n:int) : int =   (*drop every other continuation*)
                case l
                   of NoRecOrderedReadSet.NilItem => return(n)
                    | NoRecOrderedReadSet.WithK(_:any,_:any,_:item,_:item,_:cont(any),next:item) =>
                        case next
                           of NoRecOrderedReadSet.NilItem => return(n)
                            | NoRecOrderedReadSet.WithK(_:any,_:any,_:item,_:item,_:cont(any),nextNext:item) =>
                                (* NOTE: if compiled with -debug, this will generate warnings
                                 * that we are updating a bogus local pointer, however, given the
                                 * nature of the data structure, we do preserve the heap invariants*)
                                let rs : any = vpload(REMEMBER_SET, vp)
                                let newRemSet : [item, int, long, any] = alloc(l, NEXTK, #3(stamp), rs)
                                do vpstore(REMEMBER_SET, vp, newRemSet)
                                let l : mutWithK = (mutWithK) l
                                let next : mutWithK = (mutWithK) next
                                do #KPOINTER(next) := enum(0):any
                                do #NEXTK(l) := nextNext
                                apply dropKs(nextNext, I32Sub(n, 1))
                            | _ => 
                                let casted : [any, any, any] = ([any, any, any])next
                                do ccall M_Print_Long("filterRS (inner case): Impossible, tag is %lu\n", #0(casted))
                                throw exh(Fail(@"filterRS: impossible"))
                        end
                    | _ => 
                        let casted : [any, any, any] = ([any, any, any])l
                        do ccall M_Print_Long("filterRS: Impossible, tag is %lu\n", #0(casted)) 
                        throw exh(Fail(@"filterRS: impossible"))
                end
            let x :int = apply dropKs(#LASTK(readSet), #NUMK(readSet))
            do #NUMK(readSet) := x
            return();
    )
end


