(* llvm-print-util.sml
 *
 * COPYRIGHT (c) 2016 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Utility functions used during the translation from CFG to LLVM
 *)
 
structure LLVMPrinterUtil = struct
local
    
    
    structure LV = LLVMVar
    structure LT = LV.LT
    structure LB = LLVMBuilder 
    structure Ty = LLVMTy
    structure Op = LLVMOp
    structure S = String
    structure L = List
    structure V = Vector
    structure A = LLVMAttribute
    structure AS = LLVMAttribute.Set

in

      
  fun calcAddr b idx llInstr = let
    val llvTy = LB.toTy llInstr
    val zero = LB.intC(LT.i32, 0)
    val idxNum = Int.toLarge idx
  in
      (case LT.node llvTy
        of Ty.T_Ptr t => (case LT.node t
            of (Ty.T_Vector _
               | Ty.T_Array _
               | Ty.T_Struct _
               | Ty.T_UStruct _) => SOME (LB.gep_ib b (llInstr, #[zero, LB.intC(LT.i32, idxNum)]))
             
             | _ => SOME (LB.gep_ib b (llInstr, #[LB.intC(LT.i32, idxNum)]))
             
            (* esac *))
         | _ => NONE
      (* esac *))
  end
  
  (* just to keep the vp instructions consistent *)
  fun vpOffset b vpLL offset resTy = let
    val offsetLL = LB.fromC(LB.intC(LT.i64, offset))
    
    (* We take the VProc ptr, offset it, and bitcast it to the kind of pointer we want *)
    val r1 = LB.cast b Op.BitCast (vpLL, LT.mkPtr(LT.i8))
    val r2 = LB.calcAddr_ib b (r1, #[offsetLL])
    val final = LB.cast b Op.BitCast (r2, resTy)
  in
    final
  end
  
  
  (* returns ptr to new allocation and the properly offset alloc ptr *)
  fun doAlloc b allocPtr llVars = let
    val gep = LB.gep_ib b
    val cast = LB.cast b
    val mk = LB.mk b AS.empty
    
    val tagTy = LT.i64
    val llTys = L.map (fn x => LB.toTy x) llVars
    val oldAllocPtrTy = LB.toTy allocPtr
    
    (* build the types we'll need *)
    val tupleTy = LT.mkStruct(llTys)
    val heapFrameTy = LT.mkPtr(LT.mkStruct( tagTy :: tupleTy :: nil ))
    
    (*  now lets calculate addresses. the invariant about the alloc pointer is that it
        points to unallocated memory (the next allocation's header ty), so that's
        what we need to return *)
    val allocPtr = cast Op.BitCast (allocPtr, heapFrameTy)
    
    
    
    fun c idxNum = LB.intC(LT.i32, Int.toLarge idxNum)
    
    val headerAddr = gep (allocPtr, #[c 0, c 0])
    val tupleAddr = gep (allocPtr, #[c 0, c 1])
    
    val newAllocPtr = cast Op.BitCast (gep (allocPtr, #[c 1]), oldAllocPtrTy)
    
    
    fun tupleCalc idx = gep (allocPtr, #[c 0, c 1, c idx])
    
    (* now we do the writes *)
    
    fun headerTag _ = LB.fromC(LB.intC(tagTy, 1234)) (* TODO generate real header tags *)
    
    val _ = mk Op.Store #[headerAddr, headerTag tupleTy]
    
    val _ = L.foldl (fn (var, idx) =>
                ((mk Op.Store #[tupleCalc idx, var]) ; (idx + 1))) 0 llVars
    
    in
        (newAllocPtr, tupleAddr)
    end
        
      
end (* end local scope *)
end (* end LLVMPrinterUtil *)
