structure NoRecMergeRSWriteSets = 
struct

#define READ_SET_BOUND 20

    structure RS = FFReadSetMergeWriteSets

	_primcode(
		(*I'm using ![any, long, long] as the type
		 * for tvars so that the typechecker will treat them
		 * as the same type as the other STM implementations.
		 * However, only the first element is ever used*)
		typedef tvar = ![any, long];
		typedef stamp = VClock.stamp;

        extern void M_PruneRemSetAll(void*, long, void*);

		define @getFFNoRecCounter(tv : tvar / exh:exh) : any = 
			let in_trans : [bool] = FLS.@get-key(IN_TRANS / exh)
            do 	
            	if(#0(in_trans))
               	then return()
               	else 
               		do ccall M_Print("Trying to read outside a transaction!\n")
                  	let e : exn = Fail(@"Reading outside transaction\n")
                    throw exh(e)
            let myStamp : ![stamp, int, int, long] = FLS.@get-key(STAMP_KEY / exh)
            let readSet : RS.read_set = FLS.@get-key(READ_SET / exh)
            let writeSet : RS.witem = FLS.@get-key(WRITE_SET / exh)
            fun chkLog(writeSet : RS.witem) : Option.option = (*use local copy if available*)
                case writeSet
                   of RS.Write(tv':tvar, contents:any, tl:RS.witem) =>
                        if Equal(tv', tv)
                        then return(Option.SOME(contents))
                        else apply chkLog(tl)
                    | RS.NilItem => return (Option.NONE)
                end
            cont retK(x:any) = return(x)
            do  if I64Gt(#1(tv), 0:long)
                then RS.@fast-forward(readSet, writeSet, tv, retK, myStamp / exh)
                else return()
            let localRes : Option.option = apply chkLog(writeSet)
            case localRes
               of Option.SOME(v:any) => 
                    do RS.@insert-local-read(tv, v, readSet, myStamp, writeSet / exh)
                    return(v)
                | Option.NONE =>
                	fun getLoop() : any = 
                        let v : any = #0(tv)
                		let t : long = VClock.@get(/exh)
                		if I64Eq(t, #0(myStamp))
                		then return(v)
                		else
                			do RS.@validate(readSet, myStamp / exh)
                			apply getLoop()
                	let current : any = apply getLoop()
                    let captureCount : int = FLS.@get-counter()
                    if I32Eq(captureCount, 0)
                    then
                        let kCount : long = RS.@getNumK(readSet)
                        if I64Lt(kCount, READ_SET_BOUND:long)
                        then
                            do RS.@insert-with-k(tv, current, retK, writeSet, readSet, myStamp / exh)
                            let captureFreq : int = FLS.@get-counter2()
                            do FLS.@set-counter(captureFreq)
                            return(current)
                        else
                            do RS.@filterRS(readSet, myStamp / exh)
                            do RS.@insert-with-k(tv, current, retK, writeSet, readSet, myStamp / exh)
                            let captureFreq : int = FLS.@get-counter2()
                            let newFreq : int = I32Mul(captureFreq, 2)
                            do FLS.@set-counter(newFreq)
                            do FLS.@set-counter2(newFreq)
                            return(current)
                    else
                        do FLS.@set-counter(I32Sub(captureCount, 1))
                        do RS.@insert-without-k(tv, current, readSet, myStamp / exh)
                        return(current)
            end
		;

        define @commit(/exh:exh) : () =
        	let readSet : RS.read_set = FLS.@get-key(READ_SET / exh)
        	let writeSet : RS.witem = FLS.@get-key(WRITE_SET / exh)
        	let stamp : ![stamp, int, int, long] = FLS.@get-key(STAMP_KEY / exh)
        	let counter : ![long] = VClock.@get-boxed(/exh)
        	fun lockClock() : () = 
        		let current : stamp = #0(stamp)
        		let old : long = CAS(&0(counter), current, I64Add(current, 1:long))
        		if I64Eq(old, current)
        		then return()
        		else
        			do RS.@validate(readSet, stamp / exh)
        			apply lockClock()
        	do apply lockClock()
        	fun writeBack(ws:RS.witem) : () = 
        		case ws 
        		   of RS.NilItem => return()
        			| RS.Write(tv:tvar, x:any, next:RS.witem) => 
        				let x : any = promote(x)
        				do #0(tv) := x
        				apply writeBack(next)
        		end
            fun reverseWS(ws:RS.witem, new:RS.witem) : RS.witem = 
                case ws 
                   of RS.NilItem => return(new)
                    | RS.Write(tv:tvar, x:any, next:RS.witem) => apply reverseWS(next, RS.Write(tv, x, new))
                end
            let writeSet : RS.witem = apply reverseWS(writeSet, RS.NilItem)
        	do apply writeBack(writeSet)
        	do #0(counter) := I64Add(#0(stamp), 2:long) (*unlock clock*)
            let ffInfo : RS.read_set =  FLS.@get-key(FF_KEY / exh)
            do RS.@decCounts(ffInfo / exh)
        	return()
        ;

		define @atomic(f:fun(unit / exh -> any) / exh:exh) : any = 
            let in_trans : ![bool] = FLS.@get-key(IN_TRANS / exh)
            if (#0(in_trans))
            then apply f(UNIT/exh)
            else 
            	let stampPtr : ![stamp, int, int, long] = FLS.@get-key(STAMP_KEY / exh)
                do FLS.@set-key(FF_KEY, enum(0) / exh)
                cont enter() = 
                    let rs : RS.read_set = RS.@new()
                    do FLS.@set-key(READ_SET, rs / exh)  (*initialize STM log*)
                    do FLS.@set-key(WRITE_SET, RS.NilItem / exh)
                    let stamp : stamp = NoRecFF.@get-stamp(/exh)
                    do #0(stampPtr) := stamp
                    do #0(in_trans) := true
                    cont abortK() = BUMP_FABORT do #0(in_trans) := false throw enter()
                    do FLS.@set-key(ABORT_KEY, abortK / exh)
                    cont transExh(e:exn) = 
                        do case e 
                           of Fail(s:ml_string) => do ccall M_Print(#0(s)) return()
                            | _ => return()   
                        end
                    	do ccall M_Print("Warning: exception raised in transaction\n")
                        throw exh(e)
                    let res : any = apply f(UNIT/transExh)
                    do @commit(/transExh)
                    let vp : vproc = host_vproc
                    do ccall M_PruneRemSetAll(vp, #3(stampPtr))
                    do #0(in_trans) := false
                    do FLS.@set-key(READ_SET, RS.NilItem / exh)
                    do FLS.@set-key(WRITE_SET, RS.NilItem / exh)
                    do FLS.@set-key(FF_KEY, enum(0) / exh)
                    return(res)
                throw enter()
      	;

	)

	type 'a tvar = 'a PartialSTM.tvar
    val get : 'a tvar -> 'a = _prim(@getFFNoRecCounter)
    val new : 'a -> 'a tvar = NoRecFFCounter.new
    val atomic : (unit -> 'a) -> 'a = _prim(@atomic)
    val put : 'a tvar * 'a -> unit = NoRecFF.put
    val printStats : unit -> unit = NoRecFF.printStats
    val abort : unit -> 'a = NoRecFFCounter.abort
    val same : 'a tvar * 'a tvar -> bool = NoRecFF.same
    val unsafeGet : 'a tvar -> 'a = NoRecFF.unsafeGet
    val unsafePut : 'a tvar * 'a -> unit = NoRecFF.unsafePut

    val _ = Ref.set(STMs.stms, ("mergeWS", (get,put,atomic,new,printStats,abort,unsafeGet,same,unsafePut))::Ref.get STMs.stms)
end














