(* stm.pml
 *
 * COPYRIGHT (c) 2014 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Software Transactional Memory with partial aborts.
 *)

structure FullAbortSTM =
struct

    (*flat representation for read and write sets*)
    datatype 'a ritem = Read of 'a * 'a | NilRead

    datatype 'a witem = Write of 'a * 'a * 'a | NilWrite

    _primcode(

        extern void M_Print_Int(void *, int);
        extern void M_Print_Int2(void *, int, int);
        extern void M_Print_Long2(void*, long, long);
        extern void M_Print_Long (void *, long);
        extern void M_BumpCounter(void * , int);
        extern int M_SumCounter(int);

        typedef stamp = VClock.stamp;
        typedef tvar = ![any, long, long, long]; (*contents, current version stamp / lock, previous version stamp / lock, ref count (not used here)*)

        define @new(x:any / exh:exh) : tvar = 
            let tv : tvar = alloc(x, 0:long, 0:long, 0:long)
            let tv : tvar = promote(tv)
            return(tv)
        ;

        (*if these don't get inlined, we could get a type error in bom chk*)
        define @full-abort(/exh:exh) noreturn = 
            let k : cont() = FLS.@get-key(ABORT_KEY / exh)
            throw k();

        define @full-abort-any(/exh:exh) : any = 
            let k : cont() = FLS.@get-key(ABORT_KEY / exh)
            throw k();

        define @read-tvar(tv : tvar, stamp : ![stamp, int] / exh : exh) : any = 
            let v1 : stamp = #1(tv)
            do FenceRead()
            let res : any = #0(tv)
            do FenceRead()
            let v2 : stamp = #1(tv)
            if I64Eq(I64AndB(v1, 1:long), 0:long)  (*unlocked*)
            then
                if I64Eq(v1, v2)
                then 
                    if I64Lte(v1, #0(stamp))
                    then return(res)
                    else @full-abort-any(/exh)
                else @full-abort-any(/exh)
            else @full-abort-any(/exh)
        ;

        define @get(tv : tvar / exh:exh) : any = 
            let in_trans : [bool] = FLS.@get-key(IN_TRANS / exh)
            do if(#0(in_trans))
               then return()
               else do ccall M_Print("Trying to read outside a transaction!\n")
                    let e : exn = Fail(@"Reading outside transaction\n")
                    throw exh(e)
            let myStamp : ![stamp, int] = FLS.@get-key(STAMP_KEY / exh)
            let readSet : ritem = FLS.@get-key(READ_SET / exh)
            let writeSet : witem = FLS.@get-key(WRITE_SET / exh)
            fun chkLog(writeSet : witem) : Option.option = (*use local copy if available*)
                case writeSet
                    of Write(tv':tvar, contents:any, tl:witem) =>
                        if Equal(tv', tv)
                        then return(Option.SOME(contents))
                        else apply chkLog(tl)                      
                    | NilWrite => return (Option.NONE)
                end
            let localRes : Option.option = apply chkLog(writeSet)
            case localRes
                of Option.SOME(v:any) => return(v)
                 | Option.NONE =>
                    let current : any = @read-tvar(tv, myStamp / exh)
                    let newReadSet : ritem = Read(tv, readSet)
                    do FLS.@set-key(READ_SET, newReadSet / exh)
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
            let writeSet : witem = FLS.@get-key(WRITE_SET / exh)
            let newWriteSet : witem = Write(tv, v, writeSet)
            do FLS.@set-key(WRITE_SET, newWriteSet / exh)
            return(UNIT)
        ;

        define @commit(/exh:exh) : () =     
            let startStamp : ![stamp, int, int, long] = FLS.@get-key(STAMP_KEY / exh)
            fun release(locks : witem) : () = 
                case locks 
                    of Write(tv:tvar, contents:any, tl:witem) =>
                        do #CURRENT_LOCK(tv) := #PREV_LOCK(tv)   (*revert to previous lock*)
                        apply release(tl)
                     | NilWrite => return()
                end
            let readSet : ritem = FLS.@get-key(READ_SET / exh)
            let writeSet : witem = FLS.@get-key(WRITE_SET / exh)
            let rawStamp: long = #0(startStamp) (*this should be even*)
            let lockVal : long = I64Add(I64LSh(#THREAD_ID(startStamp), 1:long), 1:long)
            fun validate(readSet : ritem, locks : witem) : () = 
                case readSet 
                    of Read(tv:tvar, tl:ritem) =>
                        let owner : long = #CURRENT_LOCK(tv)
                        if I64Eq(owner, lockVal)
                        then apply validate(tl, locks)
                        else 
                            if I64Lte(owner, rawStamp)  (*still valid*)
                            then 
                                if I64Eq(I64AndB(owner, 1:long), 1:long)
                                then do apply release(locks) @full-abort(/exh)
                                else apply validate(tl, locks)
                            else do apply release(locks) @full-abort(/exh)   
                     |NilRead => return()
                end
            fun acquire(writeSet:witem, acquired:witem) : witem = 
                case writeSet 
                   of Write(tv:tvar, contents:any, tl:witem) => 
                        let owner : long = #1(tv)
                        if I64Eq(owner, lockVal)
                        then apply acquire(tl, acquired)  (*we already locked this*)
                        else
                            if I64Eq(I64AndB(owner, 1:long), 0:long)
                            then
                                if I64Lte(owner, rawStamp)
                                then
                                    let casRes : long = CAS(&1(tv), owner, lockVal)
                                    if I64Eq(casRes, owner)
                                    then 
                                        do #PREV_LOCK(tv) := owner 
                                        apply acquire(tl, Write(tv, contents, acquired))
                                    else do apply release(acquired) @full-abort-any(/exh) (*CAS failed*)
                                else do apply release(acquired) @full-abort-any(/exh) (*newer than our timestamp*)
                            else do apply release(acquired) @full-abort-any(/exh)  (*someone else locked it*)
                    | NilWrite => return(acquired)
                end
            fun update(writes:witem, newStamp : stamp) : () = 
                case writes
                    of Write(tv:tvar, newContents:any, tl:witem) =>
                        let newContents : any = promote(newContents)
                        do #0(tv) := newContents        (*update contents*)
                        do #1(tv) := newStamp           (*unlock and update stamp (newStamp is even)*)
                        apply update(tl, newStamp)          
                     | NilWrite => return()
                end
            let locks : witem = apply acquire(writeSet, NilWrite)   
            let newStamp : stamp = VClock.@inc(2:long/exh)
            if I64Eq(newStamp, rawStamp)
            then apply update(locks, I64Add(newStamp, 2:long))
            else 
                do apply validate(readSet, locks)
                apply update(locks, I64Add(newStamp, 2:long))
        ;

        define @atomic(f:fun(unit / exh -> any) / exh:exh) : any = 
                let in_trans : ![bool] = FLS.@get-key(IN_TRANS / exh)
                if (#0(in_trans))
                then apply f(UNIT/exh)
                else let stampPtr : ![stamp, int] = FLS.@get-key(STAMP_KEY / exh)
                     cont enter() = 
                         do FLS.@set-key(READ_SET, NilRead/ exh)  (*initialize STM log*)
                         do FLS.@set-key(WRITE_SET, NilWrite / exh)
                         let stamp : stamp = VClock.@get(/ exh)
                         do #0(stampPtr) := stamp
                         do #0(in_trans) := true
                         cont abortK() = BUMP_FABORT throw enter()      
                         do FLS.@set-key(ABORT_KEY, (any) abortK / exh)
                         cont transExh(e:exn) = 
                            do @commit(/transExh)  (*exception may have been raised because of inconsistent state*)
                            throw exh(e)
                         let res : any = apply f(UNIT/transExh)
                         do @commit(/transExh)
                         do #0(in_trans) := false
                         do FLS.@set-key(READ_SET, NilRead / exh)
                         do FLS.@set-key(WRITE_SET, NilWrite / exh)
                         return(res)
                     throw enter()
        ;


      define @abort(x : unit / exh : exh) : any = 
         let e : cont() = FLS.@get-key(ABORT_KEY / exh)
         throw e();
         
    )

	type 'a tvar = _prim(tvar)
	val atomic : (unit -> 'a) -> 'a = _prim(@atomic)
    val get : 'a tvar -> 'a = _prim(@get)
    val new : 'a -> 'a tvar = _prim(@new)
    val put : 'a tvar * 'a -> unit = _prim(@put)
    val abort : unit -> 'a = _prim(@abort)

    val _ = Ref.set(STMs.stms, ("full", (get,put,atomic,new,abort))::Ref.get STMs.stms)
end













 