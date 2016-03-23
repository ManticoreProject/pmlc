structure LLVMOpUtil = struct

(* because cyclic Op.dependency between LLVMOp & LLVMBuilder *)

  exception TODO of string

  structure LB = LLVMBuilder
  structure P = Prim
  structure AS = LLVMAttribute.Set
  structure LT = LLVMType
  structure A = LLVMAttribute
  structure Op = LLVMOp
  
  structure V = Vector
  structure L = List
  structure S = String


local

    val e = AS.empty
    
    (* generate a integer constant with the same type
    as the given integer instruction type *)
    fun const f instr c = LB.fromC(f (LB.toTy instr, c))
    val Iconst = const LB.intC
    val Fconst = const LB.floatC
    
    fun intTy sz = LT.mkInt(LT.cnt sz)
    val i64 = LT.i64
    val i32 = LT.i32
    val i16 = LT.i16
    val i8  = LT.i8
    val float = LT.floatTy
    val double = LT.doubleTy
    
    fun id x = x
    
    fun addrArith bb sext opc = let
        val cast = LB.cast bb
        val mk = LB.mk bb e
        
        (* TODO NOTE this was written before LB.calcAddr was added,
           and we can eliminate inttoptr/ptrtoint and sext business and just do this:
           
           %r1 = bitcast adr to i8*
           %r2 = GEP %r1, off (whatever int type it is, whether const or not, will work, make sure to negate if the opc is a subtract since GEP is additive)
           %r3 = bitcast %r2 to adrTy
           
           its unclear whether this will have a benefit as of now (3/13), and since this
           currently works lets leave it alone
            *)
        
        fun sextI64 i = cast Op.SExt (i, i64)
        fun toI64 a = cast Op.PtrToInt (a, i64)
        fun toPtr i ty = cast Op.IntToPtr (i, ty)    
        
        (* LLVM rejects sext i64 to i64, rhs must be a smaller width *)
        val doSext = if sext then sextI64 else id    
    in
        (fn [adr, off] =>
            toPtr (mk opc #[toI64 adr, doSext off]) (LB.toTy adr))
    end
    
    (* arrays in CFG are represented with "ptr to any", thus we need to do a cast.  *)
    fun getArrOffset bb elmTy arrInstr idxInstr = let
            val castedArr = LB.cast bb Op.BitCast (arrInstr, LT.mkPtr elmTy)
            val offset = LB.calcAddr_ib bb (castedArr, #[idxInstr])
        in
            offset
        end
    
    and arrayLoad bb elmTy = (fn [arr, idx] => LB.mk bb e Op.Load #[getArrOffset bb elmTy arr idx])
        
    and arrayStore bb elmTy = (fn [arr, idx, elm] => LB.mk bb e Op.Store #[getArrOffset bb elmTy arr idx, elm])
    
in

(* b is the basic Op.block, p is the 'var prim, returns
  (LB.instr list -> LV.instr) that, when applied
  to a list of arguments for this llvmPrim, adds the right
  instructions to the given block and returns the final result
  of the operation *)
fun fromPrim bb p = let
  val f = LB.mk bb
  val c = LB.cast bb
in (case p
  of (P.I32Add _ | P.I64Add _)
      => (fn [a, b] => f e Op.Add #[a, b])
      
  | (P.I32Sub _ | P.I64Sub _)
      => (fn [a, b] => f e Op.Sub #[a, b])
          
  (* NOTE Mul in LLVM works on both signed or
    unsigned integers, but in CFG types its
    not clear whether we manage signedness properly.
    same goes for constants. we might need to
    do a conversion or something. 
    
    One thing to keep in mind is that all of
    our integers in CFG _do_ wrapping, so NSW/NUW are _not_ to be added *)
    
  | (P.I32Mul _ | P.I64Mul _ | P.U64Mul _) 
      => (fn [a, b] => f e Op.Mul #[a, b])
      
  | (P.I32Div _ | P.I64Div _)
      => (fn [a, b] => f e Op.SDiv #[a, b])
      
  | (P.I32Mod _ | P.I64Mod _)
      => (fn [a, b] => f e Op.SRem #[a, b])
  
  | (P.I32LSh _ | P.I64LSh _)
      => (fn [a, b] => f e Op.Shl #[a, b])
  
  | (P.I32Neg _ | P.I64Neg _)
      => (fn [a] => f e Op.Sub #[Iconst a 0, a])
      
      
  | P.U64Div _ => (fn [a, b] => f e Op.UDiv #[a, b])
  
  | P.U64Rem _ => (fn [a, b] => f e Op.URem #[a, b])
  
  
  | (P.F32Add _ | P.F64Add _)
      => (fn [a, b] => f e Op.FAdd #[a, b])
      
  | (P.F32Sub _ | P.F64Sub _)
      => (fn [a, b] => f e Op.FSub #[a, b])
      
  | (P.F32Mul _ | P.F64Mul _)
      => (fn [a, b] => f e Op.FMul #[a, b])
      
  | (P.F32Div _ | P.F64Div _)
      => (fn [a, b] => f e Op.FDiv #[a, b])
      
  | (P.F32Neg _ | P.F64Neg _)
      => (fn [a] => f e Op.FSub #[Fconst a (FloatLit.zero false), a])
  
      (* TODO add support for LLVM instrinsics to
       perform the primops we need. 
       http://llvm.org/docs/LangRef.html#llvm-sqrt-intrinsic
       http://llvm.org/docs/LangRef.html#llvm-fabs-intrinsic
       
       a key thing we need to do is declare the intrinsics we're using at the top of the file like so:
       
       declare float     @llvm.sqrt.f32(float)
       
       define ... {
          %r = call float @llvm.sqrt.f32(float 2.0)
       }
       
       
        *)
  | (P.F32Sqrt _ | P.F64Sqrt _ | P.F32Abs _ | P.F64Abs _ )
      => raise TODO "See the todo here."


  | (P.I8RSh _ | P.I16RSh _ | P.I32RSh _ | P.I64RSh _ )
      => (fn [a, b] => f e Op.AShr #[a, b])
      
  (* conversions *)
  
  | P.I32ToI64X _ => (fn [a] => c Op.SExt (a, i64))
  | P.I32ToI64 _ => (fn [a] => c Op.ZExt (a, i64))
  | P.I64ToI32 _ => (fn [a] => c Op.Trunc (a, i32))
  
  | (P.I32ToF32 _ | P.I64ToF32 _) 
      => (fn [a] => c Op.SIToFP (a, float))
  
  | (P.I32ToF64 _ | P.I64ToF64 _) 
      => (fn [a] => c Op.SIToFP (a, double))
      
  | P.F64ToI32 _ => (fn [a] => c Op.FPToSI (a, i32))
  
  | P.I32ToI16 _ => (fn [a] => c Op.Trunc (a, i16))
  
  | P.I16ToI8 _ => (fn [a] => c Op.Trunc (a, i8))
  
  (* NOTE we can't use GEP for these address prims mostly because GEP
     requires the offsets to be constants, whereas
     AdrAdd does not nessecarily do that. we lose out on some
     alias analysis friendliness, but we can worry about that later. *)
     
  | P.AdrAddI32 _ => addrArith bb true Op.Add
  | P.AdrSubI32 _ => addrArith bb true Op.Sub
  
  | P.AdrAddI64 _ => addrArith bb false Op.Add
  | P.AdrSubI64 _ => addrArith bb false Op.Sub
  
  | ( P.AdrLoadI8 _
    | P.AdrLoadU8 _
    | P.AdrLoadI16 _
    | P.AdrLoadU16 _
    | P.AdrLoadI32 _
    | P.AdrLoadI64 _
    | P.AdrLoadF32 _
    | P.AdrLoadF64 _
    | P.AdrLoad _  ) => (fn [a] => f e Op.Load #[a])

  | (P.AdrLoadAdr _) => 
        (* we have to bitcast after this kind of load because of the type signature of AdrLoadAdr in prim-ty,
          the expected result is to be a ptr to any, and sometimes you do this load on an any type I believe,
          which would be one star short *)
        (fn [a] => c Op.BitCast (f e Op.Load #[a], LT.mkPtr(LT.uniformTy)))
  
  | ( P.AdrStoreI8 _
    | P.AdrStoreI16 _
    | P.AdrStoreI32 _
    | P.AdrStoreI64 _
    | P.AdrStoreF32 _
    | P.AdrStoreF64 _ ) => (fn [targ, value] => f e Op.Store #[targ, value])

  | (P.AdrStoreAdr _ 
     | P.AdrStore _ ) => (fn [targ, value] => 
      f e Op.Store #[c Op.BitCast (targ, LT.mkPtr(LB.toTy value)), value])
      
      (*  NOTE
          Original CFG
          (1) let _t<113C3>#1:addr(any) = &0 deq<113C4>
          ...
          (2) let _t<113CA>#1:addr(any) = AdrAddI64(_t<113C3>,_t<113C9>)
          (3) do AdrStore(_t<113CA>,_t<113BA>)
          
          
          The way we translate the CFG above is (note, deq's type is i8* in this example)
          (1) %r_127A6 = getelementptr inbounds i8, i8* %DEQ, i32 0
          ...
          (2) %r_127AA = ptrtoint i8* %r_127A6 to i64
          (2) %r_127AB = add i64 %r_127AA, %r_127A9
          (2) %r_127AC = inttoptr i64 %r_127AB to i8*
          
          (3) %r_127AD = bitcast i8* %r_127AC to %_tupTy.57**
          (3) store %_tupTy.57* %_t_cfg113BA_1279D, %_tupTy.57** %r_127AD
          
          Thus, we need to cast the target, which is _some_ address, to be
          the right pointer type in LLVM to perform the store. There may be some
          confusion in the future about the fact that anyTy and addr are the same thing,
          so be careful basically.
      *)
      
        
  

    
  (* array load operations *)
    | P.ArrLoadI32 _ => arrayLoad bb i32
    | P.ArrLoadI64 _ => arrayLoad bb i64
    | P.ArrLoadF32 _ => arrayLoad bb float
    | P.ArrLoadF64 _ => arrayLoad bb double
    
    (* load a uniform value *)
    | P.ArrLoad _ =>  arrayLoad bb LT.uniformTy	


  (* array store operations *)
    | P.ArrStoreI32 _ => arrayStore bb i32
    | P.ArrStoreI64 _ => arrayStore bb i64
    | P.ArrStoreF32 _ => arrayStore bb float
    | P.ArrStoreF64 _ => arrayStore bb double
    
    (* store a uniform value *)
    | P.ArrStore _ => arrayStore bb LT.uniformTy
    
  (* atomic Op.operations *)
    | (P.I32FetchAndAdd _ | P.I64FetchAndAdd _) => 
        (fn [targ, value] => f e (Op.Armw Op.P_Add) #[targ, value])
        
    | (P.CAS _) =>
        (fn [targ, cmp, new] => 
            (LB.extractV bb (
                f e Op.CmpXchg #[targ, cmp, new],
                #[LB.intC(i32, 0)])
            )
        )
    
    (*
  (* memory-system operations 
        NOTE in LLVM 3.8/3.9 they have intrinsics for Pause and TSC, so use those to remain platform independent *)
  
    | Pause				(* yield processor to allow memory operations to be seen *)
    | FenceRead			(* memory fence for reads *)
    | FenceWrite			(* memory fence for writes *)
    | FenceRW				(* memory fence for both reads and writes *)
  (* allocation primitives *)
    | P.AllocPolyVec _ =>     (* AllocPolyVec (n, xs): allocate in the local heap a vector 
                   * v of length n s.t. v[i] := l[i] for 0 <= i < n *)
    | P.AllocIntArray _ =>           (* allocates an array of ints in the local heap *)
    | P.AllocLongArray _ =>          (* allocates an array of longs in the local heap *)
    | P.AllocFloatArray _ =>         (* allocates an array of floats in the local heap *)
    | P.AllocDoubleArray _ =>        (* allocates an array of doubles in the local heap *)
  (* time-stamp counter *)
    | TimeStampCounter =>               (* returns the number of processor ticks counted by the TSc Op.register *)
    *)
    
    | _ => raise TODO ("primop " ^ (PrimUtil.nameOf p) ^ " not implemented")
    
    (* esac *))
  end (* end let *)
    
end (* end local *)


end (* end struct *)