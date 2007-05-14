(* alloc-fn.sml
 * 
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Generate code for allocating blocks of memory in the heap.
 *)

functor Alloc64Fn (
    structure MTy : MLRISC_TYPES
    structure Regs : MANTICORE_REGS
    structure Spec : TARGET_SPEC
    structure Types : ARCH_TYPES
    structure MLTreeComp : MLTREECOMP 
  ) : ALLOC = struct

    structure MTy = MTy
    structure T = MTy.T
    structure M = CFG
    structure Var = M.Var
    structure Ty = CFGTy
    structure W = Word64
    structure Cells = MLTreeComp.I.C

    val wordSzB = IntInf.toInt Spec.ABI.wordSzB
    val wordAlignB = IntInf.toInt Spec.ABI.wordAlignB
    val ty = MTy.wordTy

    val memory = ManticoreRegion.memory
    val apReg = Regs.apReg

    fun intLit i = T.LI (T.I.fromInt (ty, i))
    fun regExp r = T.REG (ty, r)
    fun move' (ty, r, e) = T.MV (ty, r, e)
    fun move (r, e) = move' (ty, r, e)
    fun offAp i = T.ADD (ty, regExp apReg, intLit i)
    fun gpReg r = MTy.GPReg (ty, r)
    fun mltGPR r = MTy.GPR (ty, r)

    val alignedTySzB = Types.alignedTySzB

  (* return the offset and type of the i'th element of a list of fields *)
    fun offsetOf {tys, i} = let
	  fun offset (ty :: tys, j, sz) =
		if (j >= i) then (sz, ty)
		else offset (tys, j+1, alignedTySzB ty + sz)
	    | offset ([], _, _) = raise Fail(concat[
		  "offset ", Int.toString(length tys), " of type ", CFGTy.toString (M.T_Tuple (false, tys))
		])
	  in 
	    offset (tys, 0, 0) 
	  end (* offsetOf *)

  (* compute the address of the ith element off of a 'base' address *)
    fun addrOf {lhsTy : T.ty, mty : M.ty, i : int, base : T.rexp} = let
          fun offsetOf' (M.T_Tuple(_, tys)) = offsetOf {tys=tys, i=i}
	    | offsetOf' (M.T_OpenTuple tys) = offsetOf {tys=tys, i=i}
	    | offsetOf' (M.T_Wrap ty) = (0, M.T_Raw ty)
	    | offsetOf' _ = raise Fail ("offsetOf': non-tuple type " ^ CFGTy.toString mty)
	  val (offset, _) = offsetOf' mty
	  in
	    T.ADD (ty, base, intLit offset)
	  end

  (* select the ith element off of a 'base' address *)
    fun select {lhsTy : T.ty, mty : M.ty, i : int, base : T.rexp} = let
          fun offsetOf' (M.T_Tuple(_, tys)) = offsetOf {tys=tys, i=i}
	    | offsetOf' (M.T_OpenTuple tys) = offsetOf {tys=tys, i=i}
	    | offsetOf' (M.T_Wrap ty) = (0, M.T_Raw ty)
	    | offsetOf' _ = raise Fail ("offsetOf': non-tuple type " ^ CFGTy.toString mty)
	  val (offset, lhsMTy) = offsetOf' mty
	  val addr = T.ADD(ty, base, intLit offset)
	  in 
	    case MTy.cfgTyToMLRisc lhsMTy
	     of MTy.K_FLOAT => MTy.FEXP (lhsTy, T.FLOAD (lhsTy, addr, memory))
	      | MTy.K_INT => MTy.EXP (lhsTy, T.LOAD (lhsTy, addr, memory))
	    (* esac *)
	  end (* select *)

  (* return true if the type may be represented by a pointer into the heap *)
    fun isHeapPointer M.T_Any = true
      | isHeapPointer (M.T_Wrap _) = true
      | isHeapPointer (M.T_Tuple _) = true
      | isHeapPointer (M.T_OpenTuple _) = true
      | isHeapPointer _ = false

    fun setBit (w, i, ty) = if (isHeapPointer ty) then W.orb (w, W.<< (0w1, i)) else w

  fun initObj ((ty, mltree), {i, stms, totalSize, ptrMask}) =
      let val store = MTy.store (offAp totalSize, mltree, memory)
	  val ptrMask' = setBit (ptrMask, Word.fromInt i, ty)
	  val totalSize' = alignedTySzB ty + totalSize
      in
	  {i=i+1, stms=store :: stms, totalSize=totalSize', ptrMask=ptrMask'}
      end (* initObj *)

    fun allocMixedObj args = let
	  val {i=nWords, stms, totalSize, ptrMask} = 
		List.foldl initObj {i=0, stms=[], totalSize=0, ptrMask=0w0} args
	(* create the mixed-object header word *)
	  val hdrWord = W.toLargeInt (
		  W.+ (W.orb (W.<< (ptrMask, 0w7), 
			      W.<< (W.fromInt nWords, 0w1)), 0w1) )
	in	  
	  if ((IntInf.fromInt totalSize) > Spec.ABI.maxObjectSzB)
	    then raise Fail "object size too large"
	    else (totalSize, hdrWord, stms)
	end (* allocMixedObj *)

    fun allocVectorObj args = let
	  val {i=nWords, stms, totalSize, ...} =
	        List.foldl initObj {i=0, stms=[], totalSize=0, ptrMask=0w0} args
	  val hdrWord = W.toLargeInt(W.+ (W.<< (W.fromInt nWords, 0w3), 0w4))
	  in
	    (totalSize, hdrWord, stms)
	  end

    fun allocRawObj args = let
	  val {i=nWords, stms, totalSize, ...} =
	        List.foldl initObj {i=0, stms=[], totalSize=0, ptrMask=0w0} args
	  val hdrWord = W.toLargeInt (W.+ (W.<< (W.fromInt nWords, 0w3), 0w2))
	  in
	    (totalSize, hdrWord, stms)
	  end (* allocRawObj *)

  (* determine the representation of an allocation and generate the appropriate
   * allocation code.
   *)
    fun alloc args = let
	  fun lp (hasPtr, hasRaw, (x, _)::xs) = if isHeapPointer x
		then lp(true, hasRaw, xs)
		else if CFGTy.hasUniformRep x
		  then lp (hasPtr, hasRaw, xs)
		  else lp (hasPtr, true, xs)
	    | lp (true, true, []) = allocMixedObj args
	    | lp (true, false, []) = allocVectorObj args
	    | lp (false, _, []) = allocRawObj args
	  in
(*allocMixedObj args*)
	    lp (false, false, args)
	  end

    (* *)
    fun genAlloc [] = { ptr=MTy.EXP (ty, intLit 1), stms=[] }
      | genAlloc args = let
	  val (totalSize, hdrWord, stms) = alloc args
	(* store the header word *)
	  val stms = MTy.store (offAp (~wordSzB), MTy.EXP (ty, T.LI hdrWord), memory) 
		:: stms
	(* ptrReg points to the first data word of the object *)
	  val ptrReg = Cells.newReg ()
	(* copy the original allocation pointer into ptrReg *)
	  val ptrMv = move (ptrReg, regExp apReg)
	(* bump up the allocation pointer *)
	  val bumpAp = move (apReg, offAp (totalSize+wordSzB))
	  in
	    { ptr=mltGPR ptrReg, stms=ptrMv :: rev (bumpAp :: stms) }
	  end (* genAlloc *)

  fun genWrap (mty, arg) = genAlloc [(mty, arg)]

  val heapSlopSzB = Word.- (Word.<< (0w1, 0w12), 0w512)

  (* This expression evaluates to true when the heap has enough space for szB
   * bytes.  There are 4kbytes of heap slop presubtracted from the limit pointer
   * So, most allocations need only perform the following check.
   * 
   * if (limReg - apReg <= 0)
   *    then continue;
   *    else doGC ();
   *)
  fun genAllocCheck szB =
      if Word.<= (szB, heapSlopSzB)
      then T.CMP (ty, T.Basis.LE, 
		  T.SUB (ty, T.REG (ty, Regs.limReg), T.REG (ty, Regs.apReg)),
		  T.LI 0)
      else T.CMP (ty, T.Basis.LE, 
		  T.SUB (ty, T.REG (ty, Regs.limReg), T.REG (ty, Regs.apReg)),
		  T.LI (Word.toLargeInt szB))

end (* Alloc64Fn *)
