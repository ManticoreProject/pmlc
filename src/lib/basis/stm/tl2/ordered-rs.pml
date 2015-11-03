(* ordered-rs.pml
 *
 * COPYRIGHT (c) 2014 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Chronologically ordered read sets for TL2
 *)

 

structure TL2OrderedRS = 
struct
    datatype 'a ritem = NilRead | WithK of 'a * 'a * 'a * 'a * 'a
                      | WithoutK of 'a * 'a | Abort of unit | Stamp of long * 'a

    datatype 'a witem = Write of 'a * 'a * 'a | NilWrite

    type 'a witem = 'a FullAbortSTM.witem


    val tref = FullAbortSTM.new 0
    fun getTRef() = tref

    _primcode(

    	typedef read = ![enum(3), any, ritem];

    	typedef read_set = ![int, ritem, ritem, ritem]; (*num conts, head, lastK, tail*)

        typedef stamp_rec = ![long,int,long,long]; (*current timestamp, -, old time stamp, thread ID*)

        define @get-tref = getTRef;

        (*
         * Allocate a new read set.  This will put a dummy checkpointed 
         * entry in the read set, this way we never have to check to see
         * if the tail is NULL.  Since we have to put a dummy node in the 
         * read set every time, we might as well make it a checkpoint and
         * put the full abort continuation in it.  
         * IMPORTANT: the upper bound on continuations in the read set must
         * be ODD, this way we can guarantee that this will never get filtered
         * away!
         *)
        define @new(abortK : cont(any) / exh:exh) : read_set = 
            let tref : any = @get-tref(UNIT / exh)
            let withK : ritem = WithK(tref, NilRead, abortK, NilWrite, NilRead)
            let rs : read_set = alloc(0, withK, NilRead, withK)   (*don't put checkpoint on the short path*)
            return(rs);

    	(*Note that these next two defines, rely on the fact that a heap limit check will not get
         *inserted within the body*)
        (*Add a checkpointed read to the read set*)
        define @insert-with-k(tv:any, k:cont(any), ws:witem, readSet : read_set, stamp : stamp_rec / exh:exh) : read_set = 
            let newItem : ritem = WithK(tv, NilRead, k, ws, #SHORT_PATH(readSet))
            let vp : vproc = host_vproc
            let nurseryBase : long = vpload(NURSERY_BASE, vp)
            let limitPtr : long = vpload(LIMIT_PTR, vp)
            let lastAddr : any = (any) #TAIL(readSet)
            let casted : read = (read)lastAddr
            if I64Gte(lastAddr, nurseryBase)
            then
                if I64Lt(lastAddr, limitPtr)
                then (*last item is still in nursery*)
                    do #R_ENTRY_NEXT(casted) := newItem
                    do #TAIL(readSet) := newItem
                    do #SHORT_PATH(readSet) := newItem
                    do #KCOUNT(readSet) := I32Add(#KCOUNT(readSet), 1)
                    return(readSet)
                else (*not in nursery, add last item to remember set*)
                    let newRS : read_set = alloc(I32Add(#KCOUNT(readSet), 1), #LONG_PATH(readSet), newItem, newItem)
                    let rs : any = vpload(REMEMBER_SET, vp)
                    let newRemSet : [read, int, long, any] = alloc(casted, R_ENTRY_NEXT, #3(stamp), rs)
                    do vpstore(REMEMBER_SET, vp, newRemSet)
                    do #R_ENTRY_NEXT(casted) := newItem
                    do FLS.@set-key(READ_SET, newRS / exh)
                    return(newRS)
            else (*not in nursery, add last item to remember set*)
                let newRS : read_set = alloc(I32Add(#KCOUNT(readSet), 1), #LONG_PATH(readSet), newItem, newItem)
                let rs : any = vpload(REMEMBER_SET, vp)
                let newRemSet : [read, int, long, any] = alloc(casted, R_ENTRY_NEXT, #3(stamp), rs)
                do vpstore(REMEMBER_SET, vp, newRemSet)
                do #R_ENTRY_NEXT(casted) := newItem
                do FLS.@set-key(READ_SET, newRS / exh)
                return(newRS)
        ;

        (*add a non checkpointed read to the read set*)
    	define @insert-without-k(tv:any, readSet : read_set, stamp : stamp_rec / exh:exh) : read_set =
    		let newItem : ritem = WithoutK(tv, NilRead)
    		let vp : vproc = host_vproc
    		let nurseryBase : long = vpload(NURSERY_BASE, vp)
            let limitPtr : long = vpload(LIMIT_PTR, vp)
            let lastAddr : any = (any) #TAIL(readSet)
            let casted : read = (read) lastAddr
            if I64Gte(lastAddr, nurseryBase)
            then
                if I64Lt(lastAddr, limitPtr)
                then (*last item is still in nursery*)
                    do #R_ENTRY_NEXT(casted) := newItem
                    do #TAIL(readSet) := newItem
                    return(readSet)
                else (*not in nursery, add last item to remember set*)
                    let newRS : read_set = alloc(#KCOUNT(readSet), #LONG_PATH(readSet), #SHORT_PATH(readSet), newItem)
                    let rs : any = vpload(REMEMBER_SET, vp)
                    let newRemSet : [read, int, long, any] = alloc(casted, R_ENTRY_NEXT, #3(stamp), rs)
                    do vpstore(REMEMBER_SET, vp, newRemSet)
                    do #R_ENTRY_NEXT(casted) := newItem
                    do FLS.@set-key(READ_SET, newRS / exh)
                    return(newRS)
            else (*not in nursery, add last item to remember set*)
                let newRS : read_set = alloc(#KCOUNT(readSet), #LONG_PATH(readSet), #SHORT_PATH(readSet), newItem)
                let rs : any = vpload(REMEMBER_SET, vp)
                let newRemSet : [read, int, long, any] = alloc(casted, R_ENTRY_NEXT, #3(stamp), rs)
                do vpstore(REMEMBER_SET, vp, newRemSet)
                do #R_ENTRY_NEXT(casted) := newItem
                do FLS.@set-key(READ_SET, newRS / exh)
                return(newRS)
	    ;

        define @print-headers(x:unit / exh:exh) : unit = 
            let x : ritem = WithK(enum(0):any,enum(0):any,enum(0):any,enum(0):any,enum(0):any)
            let y : ritem = WithoutK(enum(0):any,enum(0):any)
            let x : [any] = ([any]) x
            let y : [any] = ([any]) y
            do ccall M_Print_Long("WithK tag is %lu\n", #0(x))
            do ccall M_Print_Long("WithoutK tag is %lu\n", #0(y))
            return(UNIT)
        ;

    )

    val printHeaders : unit -> unit = _prim(@print-headers)
    val _ = printHeaders()



end