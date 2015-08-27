(* stm.pml
 *
 * COPYRIGHT (c) 2014 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Software Transactional Memory with partial aborts and a bounded number of continuations
 * held in the log.
 *)

(* REASONING FOR WHY WE NEED TO CHECK LOCK EACH TIME WE PERFORM A READ:
Assume the global clock and x's stamp are 0.
The value of x starts out at 10

    T1      |   T2
------------------------------
Start TX    |                 | T1's read version and vclock become 1,
x = x+1     |                 | T1's instance of x becomes 11
lock WS     |                 | 
bump clock  |                 | T1's write version and vclock become 2
            |   Start TX      | T2's read version and vclock becomes 3
validate RS |                 | 
            |   x = x+1       | T2's instance of x is 11
write back  |                 | Update x to 11 with version 2
            |   lock WS       | 
            |   bump clock    | T2's write version and vclock become 4
            |   validate RS   | Validation succeeds since x's version is 2 and T2's read version is 3
            |   write back    | Overwrites T1's update to x

*)


structure BoundedHybridPartialSTM = 
struct 

#define READ_SET_BOUND 20

#define START_TIMER let vp : vproc = host_vproc do ccall GenTimerStart(vp)
#define STOP_TIMER let vp : vproc = host_vproc do ccall GenTimerStop(vp)

    datatype 'a item = Write of 'a * 'a * 'a | NilItem | WithK of 'a * 'a * 'a * 'a * 'a
                     | WithoutK of 'a * 'a | Abort of unit

    _primcode(

        extern void * M_Print_Int(void *, int);
        extern void * M_Print_Int2(void *, int, int);
        extern void M_Print_Long (void *, long);
        extern void M_BumpCounter(void *, int);
        extern int M_SumCounter(int);
        extern void M_StartTimer();
        extern void M_StopTimer();
        extern long M_GetTimeAccum();
        extern void GenTimerStart(void *);
        extern void GenTimerStop(void *);
        extern void GenTimerPrint();
        
        typedef stamp = VClock.stamp;
        typedef tvar = ![any, long, stamp]; (*contents, lock, stamp*)
	
        typedef readItem = ![tvar,                  (*0: tvar operated on*)
                            (*cont(any)*) any,      (*1: abort continuation (enum(0) if no continuation)*)
                            any,              (*2: write list*)
                            any,                    (*3: next read item*)
                            item,item];                   (*4: next read item with a continuation*)

        typedef skipList = any;

        define @new(x:any / exh:exh) : tvar = 
            let tv : tvar = alloc(x, 0:long, 0:long)
            let tv : tvar = promote(tv)
            return(tv)
        ;

        define @unsafe-get(tv : tvar / exh:exh) : any = 
            return(#0(tv));

        define inline @logStat(x:any / exh:exh) : () = 
#ifdef COLLECT_STATS                            
            let stats : list = FLS.@get-key(STATS_KEY / exh)
            let stats : list = CONS(x, stats)
            FLS.@set-key(STATS_KEY, stats / exh)
#else
            return()
#endif          
        ;

        define @force-abort(rs : [int,item,item], startStamp:![stamp, int] / exh:exh) : () = 
            do #1(startStamp) := I32Add(#1(startStamp), 1)
            let rawStamp : stamp = #0(startStamp)
            fun validate2(readSet:item, newStamp : stamp, abortInfo : item, i:int) : () = 
                case readSet
                    of NilItem => 
                        case abortInfo
                            of NilItem => 
                                (*Extend stamp*)
                                do #0(startStamp) := newStamp
                                return()
                             | Abort(x : unit) => 
                                let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                throw abortK()
                             | WithK(tv:tvar,abortK:any,ws:item,_:item,_:item) =>
                                let abortK : cont(any) = (cont(any)) abortK
                                let current : any = #0(tv)
                                let stamp : stamp = #2(tv)
                                do if I64Eq(#1(tv), 0:long)
                                   then return()
                                   else let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                        throw abortK()
                                do if I64Lt(rawStamp, stamp)
                                   then let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                        throw abortK()
                                   else return()
                                let newRS : [int,item,item] = alloc(i, abortInfo, abortInfo)
                                do FLS.@set-key(READ_SET, newRS / exh)
                                do FLS.@set-key(WRITE_SET, ws / exh)
                                do #0(startStamp) := newStamp
                                let captureFreq : int = FLS.@get-counter2()
                                do FLS.@set-counter(captureFreq)
                                BUMP_PABORT
                                throw abortK(current)
                        end
                    | WithK(tv:tvar,k:any,ws:List.list,next:item,nextK:item) => 
                        let lock : stamp = #1(tv)
                        let stamp : stamp = #2(tv)
                        let shouldAbort : bool = if I64Eq(lock, 0:long)
                                                 then if I64Lt(stamp, rawStamp) then return(false) else return(true)
                                                 else return(true)
                        if(shouldAbort)
                        then apply validate2(next,newStamp,Abort(UNIT),0)
                        else case abortInfo
                                of Abort(x : unit) => 
                                    if Equal(k, enum(0))
                                    then apply validate2(next,newStamp,abortInfo,i)
                                    else apply validate2(next,newStamp,readSet,0)
                                 | _ => if Equal(k, enum(0)) (*either a checkpointed item or not aborting*)
                                        then apply validate2(next,newStamp,abortInfo,i)
                                        else apply validate2(next,newStamp,abortInfo,I32Add(i,1))
                             end
                    | WithoutK(tv:tvar,rest:item) => 
                        let lock : stamp = #1(tv)
                        let stamp : stamp = #2(tv)
                        let shouldAbort : bool = if I64Eq(lock, 0:long)
                                                 then if I64Lt(stamp, rawStamp) then return(false) else return(true)
                                                 else return(true)
                        if (shouldAbort)
                        then apply validate2(rest,newStamp,Abort(UNIT),0)
                        else apply validate2(rest,newStamp,abortInfo,i)
                end
            let stamp : stamp = VClock.@bump(/exh)        
            do apply validate2(#1(rs),stamp,NilItem,0)
            return()
       ;


        define @get(tv:tvar / exh:exh) : any = 
            let in_trans : [bool] = FLS.@get-key(IN_TRANS / exh)
            do if(#0(in_trans))
               then return()
               else do ccall M_Print("Trying to read outside a transaction!\n")
                    let e : exn = Fail(@"Reading outside transaction\n")
                    throw exh(e)
            let myStamp : ![stamp, int] = FLS.@get-key(STAMP_KEY / exh)
            let readSet : [int, item, item] = FLS.@get-key(READ_SET / exh)
            let writeSet : item = FLS.@get-key(WRITE_SET / exh)
            fun chkLog(writeSet : item) : Option.option = (*use local copy if available*)
                 case writeSet
                     of Write(tv':tvar, contents:any, tl:item) =>
                         if Equal(tv', tv)
                         then return(Option.SOME(contents))
                         else apply chkLog(tl)
                     | NilItem => return (Option.NONE)
                 end
            cont retK(x:any) = return(x)
            let localRes : Option.option = apply chkLog(writeSet)
            case localRes
                of Option.SOME(v:any) => return(v)
                 | Option.NONE => 
                     let current : any = 
                        fun getCurrentLoop() : any = 
                            let c : any = #0(tv)
                            let stamp : stamp = #2(tv)
                            if I64Eq(#1(tv), 0:long)
                            then if I64Lt(stamp, #0(myStamp))
                                 then return(c)
                                 else do @force-abort(readSet, myStamp / exh) (*if this returns, it updates myStamp*)
                                      apply getCurrentLoop()
                            else do Pause() apply getCurrentLoop()
                        apply getCurrentLoop()
                     let sl : item = #1(readSet)
                     if I32Lt(#0(readSet), READ_SET_BOUND)    (*still have room for more*)
                     then let captureCount : int = FLS.@get-counter()
                          if I32Eq(captureCount, 0)  (*capture a continuation*)
                          then let nextCont : item = #2(readSet)
                               let newSL : item = WithK(tv, retK, writeSet, sl, nextCont)
                               let captureFreq : int = FLS.@get-counter2()
                               do FLS.@set-counter(captureFreq)
                               let n : int = I32Add(#0(readSet), 1)  (*update number of conts*)
                               let newRS : [int, item, item] = alloc(n, newSL, newSL)
                               do FLS.@set-key(READ_SET, newRS / exh)
                               return(current)
                          else let n : int = #0(readSet)          (*don't capture cont*)
                               do FLS.@set-counter(I32Sub(captureCount, 1))
                               let nextCont : item = #2(readSet)
                               let newSL : item = WithoutK(tv, sl)
                               let newRS : [int,item,item] = alloc(n, newSL, nextCont)
                               do FLS.@set-key(READ_SET, newRS / exh)
                               return(current)
                     else fun dropKs(l:item, n:int) : int =   (*drop every other continuation*)
                              case l
                                of NilItem => return(n)
                                 | WithK(_:tvar,_:cont(any),_:List.list,_:item,next:item) =>
                                    case next
                                        of NilItem => return(n)
                                         | WithK(_:tvar,_:cont(any),_:List.list,_:item,nextNext:item) =>
                                            (* NOTE: if compiled with -debug, this will generate warnings
                                             * that we are updating a bogus local pointer, however, given the
                                             * nature of the data structure, we do preserve the heap invariants*)
                                            let l : readItem = (readItem) l
                                            let next : readItem = (readItem) next
                                            do #2(next) := enum(0):any
                                            do #5(l) := nextNext
                                            apply dropKs(nextNext, I32Sub(n, 1))
                                    end
                             end
                          let nextCont : item = #2(readSet)
                          let n : int = apply dropKs(nextCont, #0(readSet))
                          let newSL : item = WithoutK(tv, sl)
                          let newRS : [int, item, item] = alloc(n, newSL, nextCont)
                          let captureFreq : int = FLS.@get-counter2()
                          let newFreq : int = I32Mul(captureFreq, 2)
                          do FLS.@set-counter(I32Sub(newFreq, 1))
                          do FLS.@set-counter2(newFreq)
                          do FLS.@set-key(READ_SET, newRS / exh)
                          return(current)
            end
        ;

        define @put(arg:[tvar, any] / exh:exh) : unit =
            let in_trans : [bool] = FLS.@get-key(IN_TRANS / exh)
            do if(#0(in_trans))
               then return()
               else do ccall M_Print("Trying to write outside a transaction!\n")
                    let e : exn = Fail(@"Writing outside transaction\n")
                    throw exh(e)
            let tv : tvar = #0(arg)
            let v : any = #1(arg)
            let writeSet : item = FLS.@get-key(WRITE_SET / exh)
            let newWriteSet : item = Write(tv, v, writeSet)
            do FLS.@set-key(WRITE_SET, newWriteSet / exh)
            return(UNIT)
        ;

        define @commit(/exh:exh) : () = 
            let startStamp : ![stamp, int] = FLS.@get-key(STAMP_KEY / exh)
            do #1(startStamp) := I32Add(#1(startStamp), 1)
            fun release(locks : item) : () = 
                case locks 
                    of Write(tv:tvar, contents:any, tl:item) =>
                        do #1(tv) := 0:long         (*unlock*)
                        apply release(tl)
                     | NilItem => return()
                end
                
            let rs : [int, item, item] = FLS.@get-key(READ_SET / exh)
            let readSet : item = #1(rs)
            let writeSet : item = FLS.@get-key(WRITE_SET / exh)
            let rawStamp: long = #0(startStamp)
            fun validate2(readSet:item, locks:item, newStamp : stamp, abortInfo : item, i:int, j:int, n:int) : () = 
                case readSet
                    of NilItem => 
                        case abortInfo
                            of NilItem => return() (*no violations detected*)
                             | WithK(tv:tvar,abortK:any,ws:item,_:item,_:item) =>(*
                                do ccall M_Print_Int2("Aborting to postion %d of %d\n", n, j) *)
                                let stats : list = FLS.@get-key(STATS_KEY / exh)
                                let newStat : [int,int,int,int] = alloc(2, n, j, #1(startStamp))
                                let stats : list = CONS(newStat, stats)
                                do FLS.@set-key(STATS_KEY, stats / exh)
                                if Equal(abortK, enum(0))
                                then do apply release(locks)
                                     let abortK :cont() = FLS.@get-key(ABORT_KEY / exh)
                                     let captureFreq : int = FLS.@get-counter2()
                                     let newFreq : int = I32Div(captureFreq, 2)
                                     do FLS.@set-counter2(newFreq) 
                                     throw abortK()  (*no checkpoint found*)
                                else do apply release(locks)
                                     let abortK : cont(any) = (cont(any)) abortK
                                     let current : any = #0(tv)
                                     let stamp : stamp = #2(tv)
                                     do if I64Eq(#1(tv), 0:long)
                                        then return()
                                        else let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                            throw abortK()
                                     do if I64Lt(rawStamp, stamp)
                                        then let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                             throw abortK()
                                        else return()
                                     let newRS : [int,item,item] = alloc(i, abortInfo, abortInfo)
                                     do FLS.@set-key(READ_SET, newRS / exh)
                                     do FLS.@set-key(WRITE_SET, ws / exh)
                                     do #0(startStamp) := newStamp
                                     let captureFreq : int = FLS.@get-counter2()
                                     do FLS.@set-counter(captureFreq)
                                     BUMP_PABORT
                                     throw abortK(current)
                             | WithoutK(tv:tvar,_:item) =>
                                do apply release(locks)
                                let abortK :cont() = FLS.@get-key(ABORT_KEY / exh)
                                let captureFreq : int = FLS.@get-counter2()
                                let newFreq : int = I32Div(captureFreq, 2)
                                do FLS.@set-counter2(newFreq) 
                                throw abortK()  (*no checkpoint found*)
                        end                          
                    | WithK(tv:tvar,k:any,ws:List.list,next:item,nextK:item) => 
                        let stamp : stamp = #2(tv)
                        if I64Lt(rawStamp, stamp)
                        then apply validate2(next,locks,newStamp,readSet,0,I32Add(j, 1), 0)
                        else case abortInfo
                               of NilItem => 
                                    if Equal(k, enum(0))            (*continuation was dropped*)
                                    then apply validate2(next, locks,newStamp,abortInfo,i,I32Add(j, 1), I32Add(n,1))
                                    else apply validate2(next, locks,newStamp, abortInfo, I32Add(i, 1),I32Add(j, 1), I32Add(n, 1))
                                | WithK(_:tvar,k':any,_:List.list,_:item,_:item) =>  (*already going to abort*)
                                    if Equal(k', enum(0))   (*don't have checkpoint*)
                                    then if Equal(k,enum(0))        (*don't have one here either*)
                                         then apply validate2(next,locks,newStamp,abortInfo,i,I32Add(j, 1), 0) 
                                         else apply validate2(next,locks,newStamp,readSet,0,I32Add(j, 1), 0) (*use this checkpoint*)
                                    else if Equal(k,enum(0))
                                         then apply validate2(next,locks,newStamp,abortInfo,i,I32Add(j, 1), I32Add(n, 1))
                                         else apply validate2(next,locks,newStamp,abortInfo,I32Add(i,1),I32Add(j, 1), I32Add(n, 1))
                               | _ => if Equal(k,enum(0))
                                      then apply validate2(next,locks,newStamp,abortInfo,i,I32Add(j, 1), 0)
                                      else apply validate2(next,locks,newStamp,readSet, 0,I32Add(j, 1),0)
                             end
                    | WithoutK(tv:tvar,rest:item) => 
                        if I64Lt(#2(tv), rawStamp)
                        then apply validate2(rest, locks,newStamp,abortInfo,i,I32Add(j, 1), I32Add(n, 1))
                        else apply validate2(rest,locks,newStamp,readSet,0,I32Add(j, 1), 0)
                end
            fun validate(readSet:item, locks:item, newStamp : stamp, abortInfo : item, i:int) : () = 
                case readSet
                    of NilItem => 
                        case abortInfo
                            of NilItem => return() (*no violations detected*)
                             | WithK(tv:tvar,abortK:any,ws:item,_:item,_:item) =>
                                if Equal(abortK, enum(0))
                                then do apply release(locks)
                                     let abortK :cont() = FLS.@get-key(ABORT_KEY / exh)
                                     let captureFreq : int = FLS.@get-counter2()
                                     let newFreq : int = I32Div(captureFreq, 2)
                                     do FLS.@set-counter2(newFreq) 
                                     throw abortK()  (*no checkpoint found*)
                                else do apply release(locks)
                                     let abortK : cont(any) = (cont(any)) abortK
                                     let current : any = #0(tv)
                                     let stamp : stamp = #2(tv)
                                     do if I64Eq(#1(tv), 0:long)
                                        then return()
                                        else let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                            throw abortK()
                                     do if I64Lt(rawStamp, stamp)
                                        then let abortK : cont() = FLS.@get-key(ABORT_KEY / exh)
                                             throw abortK()
                                        else return()
                                     let newRS : [int,item,item] = alloc(i, abortInfo, abortInfo)
                                     do FLS.@set-key(READ_SET, newRS / exh)
                                     do FLS.@set-key(WRITE_SET, ws / exh)
                                     do #0(startStamp) := newStamp
                                     let captureFreq : int = FLS.@get-counter2() 
                                     do FLS.@set-counter(captureFreq)
                                     BUMP_PABORT
                                     throw abortK(current) 
                             | WithoutK(tv:tvar,_:item) =>
                                do apply release(locks)
                                let abortK :cont() = FLS.@get-key(ABORT_KEY / exh)
                                let captureFreq : int = FLS.@get-counter2()
                                let newFreq : int = I32Div(captureFreq, 2)
                                do FLS.@set-counter2(newFreq) 
                                throw abortK()  (*no checkpoint found*)
                        end                          
                    | WithK(tv:tvar,k:any,ws:List.list,next:item,nextK:item) => 
                        let stamp : stamp = #2(tv)
                        if I64Lt(rawStamp, stamp)
                        then if Equal(k, enum(0))
                             then apply validate(next,locks,newStamp,Abort(UNIT),0)
                             else apply validate(next,locks,newStamp,readSet,0)
                        else case abortInfo
                               of NilItem => apply validate(next, locks,newStamp,abortInfo,i) 
                                | WithK(_:tvar,k':any,_:List.list,_:item,_:item) =>  (*k is necessarily non-null*)
                                    if Equal(k,enum(0))
                                    then apply validate(next,locks,newStamp,abortInfo,i)
                                    else apply validate(next,locks,newStamp,abortInfo,I32Add(i,1)) 
                               | Abort(_ : unit) => 
                                    if Equal(k,enum(0))
                                    then apply validate(next,locks,newStamp,abortInfo,i)
                                    else apply validate(next,locks,newStamp,readSet,0) (*use this continuation*)
                               | _ => let e : exn = Fail(@"Impossible: validate\n")
                                      throw exh(e)
                             end
                    | WithoutK(tv:tvar,rest:item) => 
                        if I64Lt(#2(tv), rawStamp)
                        then apply validate(rest, locks,newStamp,abortInfo,i)
                        else apply validate(rest,locks,newStamp,Abort(UNIT),0)
                end
            fun acquire(ws:item, acquired : item) : item = 
                case ws
                    of Write(tv:tvar, contents:any, tl:item) =>
                        let casRes : long = CAS(&1(tv), 0:long, rawStamp) (*lock it*)
                        if I64Eq(casRes, 0:long)  (*locked for first time*)
                        then apply acquire(tl, Write(tv, contents, acquired))
                        else if I64Eq(casRes, rawStamp)    (*already locked it*)
                             then apply acquire(tl, acquired)
                             else (*release, but don't end atomic*)
                                  fun release(locks : item) : () = 
                                    case locks 
                                        of Write(tv:tvar, contents:any, tl:item) =>
                                            do #1(tv) := 0:long         (*unlock*)
                                            apply release(tl)
                                         | NilItem => return()
                                    end
                                  do apply release(acquired) 
                                  apply acquire(writeSet, NilItem)
                     |NilItem => return(acquired)
                end
            fun update(writes:item, newStamp : stamp) : () = 
                case writes
                    of Write(tv:tvar, newContents:any, tl:item) =>
                        let newContents : any = promote(newContents)
                        do #2(tv) := newStamp            (*update version stamp*)
                        do #0(tv) := newContents         (*update contents*)
                        do #1(tv) := 0:long              (*unlock*)
                        apply update(tl, newStamp)       (*update remaining*)
                     | NilItem => return()
                end
            let locks : item = apply acquire(writeSet, NilItem)
            let newStamp : stamp = VClock.@bump(/exh)
#ifdef COLLECT_STATS
            do apply validate2(#1(rs),locks,newStamp,NilItem,0,0,0)
#else            
            do apply validate(#1(rs),locks,newStamp,NilItem,0)
#endif    
            do apply update(locks, newStamp)
            do #1(startStamp) := I32Sub(#1(startStamp), 1)
            return()
        ;

        define inline @force-gc() : () = 
            let vp : vproc = host_vproc
            let limitPtr : any = vpload(LIMIT_PTR, vp)
            do vpstore(ALLOC_PTR, vp, limitPtr)
            return()   
        ;
        
        define @atomic(f:fun(unit / exh -> any) / exh:exh) : any = 
            
            let in_trans : ![bool] = FLS.@get-key(IN_TRANS / exh)
            if (#0(in_trans))
            then apply f(UNIT/exh)
            else let stampPtr : ![stamp, int] = FLS.@get-key(STAMP_KEY / exh)
                 do #1(stampPtr) := 0
                 cont enter() = 
                    (* do FLS.@set-counter(0) *)
                     do FLS.@set-key(READ_SET, alloc(0, NilItem, NilItem) / exh)  (*initialize STM log*)
                     do FLS.@set-key(WRITE_SET, NilItem / exh)
                     let stamp : stamp = VClock.@bump(/exh)
                     do #0(stampPtr) := stamp
                     do #0(in_trans) := true
                     cont abortK() = BUMP_FABORT do #0(in_trans) := false throw enter()
                     do FLS.@set-key(ABORT_KEY, abortK / exh)
                     cont transExh(e:exn) = 
                        do ccall M_Print("Warning: exception raised in transaction\n")
                        do @commit(/exh)  (*exception may have been raised because of inconsistent state*)
                        throw exh(e)
                     let res : any = apply f(UNIT/transExh)
                     do @commit(/transExh)
                     (*do ccall M_Print_Int("Aborted this transaction %d times\n", #1(stampPtr))  *)
                     do #0(in_trans) := false
                     do FLS.@set-key(READ_SET, nil / exh)
                     do FLS.@set-key(WRITE_SET, NilItem / exh)
                     return(res)
                     
                 throw enter()
      ;

      define @timeToString = Time.toString;
      
      define @print-stats(x:unit / exh:exh) : unit = 
        PRINT_PABORT_COUNT
        PRINT_FABORT_COUNT
        PRINT_COMBINED
        return(UNIT);
        
      define @abort(x : unit / exh : exh) : any = 
         let e : cont() = FLS.@get-key(ABORT_KEY / exh)
         throw e();        

      define @tvar-eq(arg : [tvar, tvar] / exh : exh) : bool = 
         if Equal(#0(arg), #1(arg))
         then return(true)
         else return(false);

      define @rs-length(x : unit / exh:exh) : unit = 
        let rs : [int,item,item] = FLS.@get-key(READ_SET / exh)
        fun lp(readSet : item, i:int) : int = 
            case readSet    
                of WithK(tv:tvar,k:any,ws:List.list,next:item,nextK:item) => apply lp(next,I32Add(i,1))
                 | WithoutK(tv:tvar,rest:item) => apply lp(rest, I32Add(i, 1))
                 | NilItem => return(i)
            end
        fun contains(item : tvar, seen:List.list) : bool = 
            case seen
                of CONS(hd:tvar, tl:List.list) => 
                    if Equal(item, hd)
                    then return(true)
                    else apply contains(item, tl)
                 | nil => return(false)
            end
        fun lp2(readSet:item, i:int, seen:List.list) : int = 
            case readSet    
                of WithK(tv:tvar,k:any,ws:List.list,next:item,nextK:item) => 
                    let b : bool = apply contains(tv, seen)
                    if(b)
                    then apply lp2(next, i, seen)
                    else apply lp2(next,I32Add(i,1), CONS(tv, seen))
                 | WithoutK(tv:tvar,rest:item) =>
                    let b : bool = apply contains(tv, seen)
                    if(b)
                    then apply lp2(rest, i, seen)
                    else apply lp2(rest,I32Add(i,1), CONS(tv, seen))
                 | NilItem => return(i)
            end
        let n : int = apply lp(#1(rs), 0)
        let n2 : int = apply lp2(#1(rs), 0, nil)
        do ccall M_Print_Int2("Read set length is %d, with %d unique tvars\n", n, n2)
        
        return(UNIT);

        define @get-stats(x:unit / exh:exh) : list = 
#ifdef COLLECT_STATS        
            let stats : list = FLS.@get-key(STATS_KEY / exh)
            return(stats);
#else
            return(nil);
#endif

        define @dump-stats(x : [ml_string, list] / exh:exh) : unit = 
#ifdef COLLECT_STATS
            let f : ml_string = #0(x)
            let data : list = #1(x)
            let stream : TextIO.outstream = TextIO.@open-out(f / exh)
            fun outLine(x : [int] / exh:exh) : () = 
                let i1 : ml_string = Int.@to-string(x / exh) (*
                let i2 : ml_string = Int.@to-string(alloc(#1(x)) / exh)
                let i3 : ml_string = Int.@to-string(alloc(#2(x)) / exh)
                let i4 : ml_string = Int.@to-string(alloc(#3(x)) / exh)*)
                let sList : list = CONS(i1, CONS(@", ", nil))
                let str : ml_string = String.@string-concat-list(sList / exh)
                let _ : unit = TextIO.@output-line(alloc(str, stream) / exh)
                return ()
            do PrimList.@app(outLine, data / exh)
            let x : unit = TextIO.@close-out(stream / exh)
            return(UNIT);
#else
            return(UNIT);
#endif            

        define @checkpoint(x:tvar / exh:exh) : unit = 
            let readSet : [int, item, item] = FLS.@get-key(READ_SET / exh)
            let writeSet : item = FLS.@get-key(WRITE_SET / exh)
            cont k(x:any) = return(UNIT)
            let newSL : item = WithK(x,k,writeSet,#1(readSet),#2(readSet))
            let newReadSet : [int, item, item] = alloc(I32Add(#0(readSet), 1), newSL, newSL)
            do FLS.@set-key(READ_SET, newReadSet / exh)
            return(UNIT);

        define @turn-off-checkpoints(x:unit / exh:exh) : unit = 
            do FLS.@set-counter2(10000000)
            return(UNIT);

        define @print-timer(x:unit / exh:exh) : unit = 
            do ccall GenTimerPrint()
            return(UNIT);      
         
        define @commit-wrapper(x:unit / exh:exh) : unit = 
            do @commit(/exh)
            return(UNIT);

        define @unsafe-put(arg : [tvar, any] / exh:exh) : unit = 
            let tv : tvar = #0(arg)
            let x : any = #1(arg)
            let x : any = promote(x)
            do #0(tv) := x
            return(UNIT)   
        ;

    )

    type 'a tvar = 'a PartialSTM.tvar
    val atomic : (unit -> 'a) -> 'a = _prim(@atomic)
    val get : 'a tvar -> 'a = _prim(@get)
    val new : 'a -> 'a tvar = _prim(@new)
    val put : 'a tvar * 'a -> unit = _prim(@put)
    val printStats : unit -> unit = _prim(@print-stats)
    val abort : unit -> 'a = _prim(@abort)
    val unsafeGet : 'a tvar -> 'a = _prim(@unsafe-get)
    val same : 'a tvar * 'b tvar -> bool = _prim(@tvar-eq)
    val unsafePut : 'a tvar * 'a -> unit = _prim(@unsafe-put)

    val rsLength : unit -> unit = _prim(@rs-length)

    val getStats : unit -> 'a list = _prim(@get-stats)
    val dumpStats : string * 'a list -> unit = _prim(@dump-stats)
    val turnOffCheckpointing : unit -> unit = _prim(@turn-off-checkpoints)
    val checkpoint' : 'a tvar -> unit = _prim(@checkpoint)

    val checkpointTRef  = new 0

    
    val commit : unit -> unit = _prim(@commit-wrapper)

    fun checkpoint() = checkpoint' checkpointTRef

    val printTimer : unit -> unit = _prim(@print-timer)
    
    val _ = Ref.set(STMs.stms, ("bounded", (get,put,atomic,new,printStats,abort,unsafeGet,same,unsafePut))::Ref.get STMs.stms)

end












 