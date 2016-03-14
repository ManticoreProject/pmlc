(* llvm-printer.sml
 *
 * COPYRIGHT (c) 2015 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Outputs a CFG program as textual LLVM IR. 
 *    - Depends on the predecessor CFG pass.
 *    - Compatible with LLVM 3.8
 *)

functor LLVMPrinter (structure Spec : TARGET_SPEC) : sig

    val output : (TextIO.outstream * CFG.module) -> unit

  end = struct

    (*

      Plan: since CFG is basically in SSA form, the main things we need to
            keep track of are the pinned register values (allocation ptr,
            vproc, limit ptr, etc) as they change and are changed by various
            actions. For everything else we ought to be able to just reuse the
            vars and not keep track of those things. All of the
            information needed seems to be otherwise already present in the CFG
            representation.

            Another difference is the way we generate heap checks. since we
            need to spill and reload live vars in the case of a GC occuring,
            along with having the std regs change in that case, we need to
            introduce extra GC bbs for the GCs occuring and introduce phis
            for the following block. An additional optimization we talked about
            was to mark such blocks as cold paths so they're not stuck in the middle
            of a hot path.

      *)

  structure C = CFG
  structure CV = CFG.Var
  structure CL = CFG.Label
  structure CT = CFGTy
  structure CTU = CFGTyUtil
  structure CF = CFunctions
  structure S = String
  structure L = List
  structure V = Vector

  (*  *)
  structure LV = LLVMVar
  structure LB = LLVMBuilder 
  structure A = LLVMAttribute
  structure AS = LLVMAttribute.Set

  structure LT = LV.LT
  structure Ty = LLVMTy
  structure Op = LLVMOp
  structure OU = LLVMOpUtil
  structure P = Prim
  structure PU = PrimUtil
  

fun output (outS, module as C.MODULE { name = module_name,
                                       externs = module_externs,
                                       code = module_code } ) = let
  
  (* print/string utils *)
  fun pr s = TextIO.output(outS, s)
  fun prl s = pr(S.concat s)
  val i2s = Int.toString

  fun mapSep(f, init, sep, lst) = List.foldr 
                      (fn (x, nil) => f(x) :: nil 
                        | (x, y) => let val fx = f(x) in
                          if fx = "" (* skip empty strings *)
                          then y
                          else fx :: sep :: y
                        end)
                      init
                      lst



  (* links together the attribute number and the standard attribute list *)

  datatype llvm_attributes = MantiFun | ExternCFun

  fun stdAttrs (MantiFun) = "naked nounwind"

    (* TODO: because I'm not sure of the effect inlining a C func into a naked func right now. *)
    | stdAttrs (ExternCFun) = "noinline" 

  (**)

  (* translation utils *)
  local
    (* TODO: this might be pointless because one can access the exported
       name through the label once its encountered. *)
    val externInfo = ref CL.Map.empty
  in

    fun externInfoAdd (v : C.label, s : string) : unit = 
      externInfo := CL.Map.insert(!externInfo, v, s)

    fun externInfoGet (v : C.label) : string = 
      (case CL.Map.find(!externInfo, v)
        of SOME s => s
         | NONE => 
            raise Fail ("Unable to find extern name associated with var " ^ (CL.toString v))
      (* end case *))

  end

  (* translation environment utilities *)
  
  (* implicit machine values according to CFG *)
  datatype machineVal 
    = MV_Alloc
    | MV_Vproc
    
  fun machineInfo mv = (case mv
    of MV_Alloc => (0, "allocPtr", LT.allocPtrTy)
     | MV_Vproc => (1, "vprocPtr", LT.vprocTy)
    (* end case *))
    
  fun machineValIdx mv = #1(machineInfo mv)
  fun machineValStr mv = #2(machineInfo mv)
  fun machineValTy  mv = #3(machineInfo mv)
      
  fun IdxMachineVal n = (case n
      of 0 => SOME MV_Alloc
       | 1 => SOME MV_Vproc
       | _ => NONE
      (* end case *))
  
  val numMachineVals = 2

  datatype gamma = ENV of {
    labs : LV.var CL.Map.map,    (* CFG Labels -> LLVMVars *)
    vars : LB.instr CV.Map.map,     (* CFG Vars -> LLVM Instructions *)
    mvs : LB.instr vector          (* current LLVM Instructions representing machine vals *)
  }

  fun lookupV (ENV{vars,...}, v) = 
    (case CV.Map.find(vars, v)
      of SOME lv => lv
       | NONE => raise Fail ("lookupV -- unknown CFG Var: " ^ CV.toString v)
    (* esac *))

  fun lookupL (ENV{labs,...}, l) = 
    (case CL.Map.find(labs, l)
      of SOME ll => ll
       | NONE => raise Fail ("lookupL -- unknown CFG Label: " ^ CL.toString l)
    (* esac *))
    
  fun lookupMV (ENV{mvs,...}, kind) = Vector.sub(mvs, machineValIdx kind)

  fun insertV (ENV{vars, labs, mvs}, v, lv) = 
        ENV{vars=(CV.Map.insert(vars, v, lv)), labs=labs, mvs=mvs}

  fun insertL (ENV{vars, labs, mvs}, l, ll) = 
        ENV{vars=vars, labs=(CL.Map.insert(labs, l, ll)), mvs=mvs}
        
  fun updateMV(ENV{vars, labs, mvs}, kind, lv) =
        ENV{vars=vars, labs=labs,
            mvs= Vector.update(mvs, machineValIdx kind, lv)}

  (* end translation environment utilities *)

  
  (* Terminators, aka transfers in CFG *)

  fun mkTransfer (t : C.transfer) = (case t

    of (C.Switch _) => raise Fail "implement me"

    (* this will require inspecting the Prim.cond and generating the test as well *)
     | (C.If _) => raise Fail "implement me"

     (* br *)
     | (C.Goto _) => raise Fail "implement me"


     (* see above. also, need to figure out the difference between these two. *)
     | (C.HeapCheck _) => raise Fail "implement me"
     | (C.HeapCheckN _) => raise Fail "implement me"


     (* generate musttail calls *)
     | (C.StdApply _) => raise Fail "implement me"
     | (C.StdThrow _) => raise Fail "implement me"
     | (C.Apply _) => raise Fail "implement me"

     | _ => raise Fail "not sure how to handle AllocCCall right now "

    (* end case *))

  (* end of Terminators *)


  (* Basic Blocks *)

  fun mkBasicBlocks (initEnv : gamma, start : C.block, body : C.block list, llvmCC) : string list = let
    (* no branches should be expected to target the start block, 
      because they should be calls (the start block has the type of the function
    and for all intents and purposes it represents the function) *)

      fun convertLabs (C.BLK{lab,...}) = (lab, LV.convertLabel lab)

      val initialEnv = L.foldr (fn ((old, new), acc) => insertL(acc, old, new))
                  initEnv 
                  (L.map convertLabs body)

      (* TODO(kavon): not sure if it's correct to skip adding start block to environment.
          current assumption is that nobody will branch to start block, but instead make
          a call to it, and the function's LLVM name should already be in environment
          at this point. *)

      fun init f (b as C.BLK{lab, body, exit, args}) = let
          val llArgs  = L.map LV.convert args
          val env = L.foldr (fn ((old, new), acc) => insertV(acc, old, LB.fromV new))
                      initialEnv
                      (ListPair.zip(args, llArgs))
          
          val b = LB.new (f lab, llArgs)
        in
          fillBlock b (env, body, exit)
        end

      fun mkStartBlock (C.BLK{body, exit, ...}, (cc, ccRegs, mvRegs)) = let
      (* start needs to be treated specially because its inputs
         are the parameters to the function that need a special calling convention.
         also nobody can branch to the start block so we don't need to add it to the env *)
         
         val inputs = L.map (fn (_, var, _) => var) (mvRegs @ ccRegs)
         
         val blk = LB.new(LV.new("entry", LT.labelTy), inputs)
         
         fun addBitcastCC (((_, cfgVar), (_, llReg, realTy)), acc) = let
                val castPair = (LV.typeOf llReg, realTy)
                val argPair = (LB.fromV llReg, realTy)
                val newVar = LB.cast blk (Op.autoCast castPair) argPair
            in
                insertV(acc, cfgVar, newVar) (*  *)
            end
            
        fun addCastsMV ((i, llReg, realTy), acc) = let
               val castPair = (LV.typeOf llReg, realTy)
               val argPair = (LB.fromV llReg, realTy)
               val newVar = LB.cast blk (Op.autoCast castPair) argPair
               val SOME mv = IdxMachineVal i
           in
               updateMV(acc, mv, newVar)
           end
         
         
         val env = L.foldl 
            addBitcastCC
            initialEnv
            (ListPair.zipEq(cc, ccRegs))
            
        val env = L.foldl addCastsMV env mvRegs
      
        in
            fillBlock blk (env, body, exit)
        end


      val startBlock = mkStartBlock(start, llvmCC)
      
      (* TODO shouldn't lookup or use initialEnv imo, might have to rethink this *)
      val bodyBlocks = L.map (init (fn lab => lookupL(initialEnv, lab))) body

    in
      L.map LB.toString (startBlock::bodyBlocks)
    end
      


  and fillBlock (b : LB.t) (initialEnv : gamma, body : C.exp list, exit : C.transfer) : LB.bb = let
    
    (* a jump list is a (label * var list) which indicates
       where a jump comes from, and the names of the vars from that BB.
       We'll need to stick a sequence of phis at the beginning of each
       BB once we know all of the control flow in the program. in particular,
       during the generation of transfers we'll be creating new blocks.

       In the meantime, we should save the args and preds into the block, and later
        once we terminate the block we'll generate the following at the beginning
        of the block:

        arg[i] <- phi [ jump[k].arg[i], jump[k].label ], [ jump[k+1].arg[i], jump[k+1].label ], ...
        arg[i+1] <- phi [ jump[k].arg[i+1], jump[k].label ], [ jump[k+1].arg[i+1], jump[k+1].label ], ...
        ...
    *)
    
      (* handle control transfers. i think you need to actually have
      fill block return a LB.t and a thunk LB.t -> LB.bb to finish the block,
      because we need to go over all other blocks before finishing the block so
      that the terminator function adds the proper phi's to the block when it finializes it.
      *)
      
      (* handy stuff used in several places *)
      
      (* the noattr instruction maker *)
      val mk = LB.mk b AS.empty
      val cast = LB.cast b
      
      fun stubIt env cfgVar = let
      (* NOTE stubIt is for temporary usage only. will assign
         a new LHS llvm var to an undef value of the
         converted CFG type, and place a mapping in the env.
      *)
          val ty = CV.typeOf cfgVar
          val targetTy = LT.typeOf ty
          val newLLVar = LB.fromC(LB.undef targetTy)
      in
          insertV(env, cfgVar, newLLVar)
      end
      
      fun calcAddr idx llInstr = let
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
      fun vpOffset vpLL offset resTy = let
        val offsetLL = LB.fromC(LB.intC(LT.i64, offset))
        
        (* We take the VProc ptr, offset it, and bitcast it to the kind of pointer we want *)
        val r1 = cast Op.BitCast (vpLL, LT.mkPtr(LT.i8))
        val r2 = LB.calcAddr_ib b (r1, #[offsetLL])
        val final = cast Op.BitCast (r2, resTy)
      in
        final
      end
      
      (* end handy stuff *)
      
      fun finish(env, exit) = LB.retVoid b
      
      (* handle the list of exp's in a CFG block *)
      and process(env, []) = env
        | process(env, x::xs) = let
          val env =
            (case x
              of C.E_Var rhs => genAssignments(env, rhs)
               | C.E_Const rhs => genConst(env, rhs)
               | C.E_Cast rhs => genCast(env, rhs)
               | C.E_Label rhs => genLabel(env, rhs)
               | C.E_Select rhs => genSelect(env, rhs)
               | C.E_Update rhs => genUpdate(env, rhs)
               | C.E_AddrOf rhs => genAddrOf(env, rhs)
               | C.E_Alloc rhs => genAlloc(env, rhs)
               | C.E_GAlloc rhs => genGAlloc(env, rhs)
               | C.E_Promote rhs => genPromote(env, rhs)
               | C.E_Prim0 rhs => genPrim0(env, rhs)
               | C.E_Prim rhs => genPrim(env, rhs)
               | C.E_CCall rhs => genCCall(env, rhs)
               | C.E_HostVProc rhs => genHostVProc(env, rhs)
               | C.E_VPLoad rhs => genVPLoad(env, rhs)
               | C.E_VPStore rhs => genVPStore(env, rhs)
               | C.E_VPAddr rhs => genVPAddr(env, rhs)
               (* | _ => raise Fail "(llvm-backend) error: unexpected exp type encountered in CFG representation" *)
              (* esac *))
          in
            process(env, xs)
          end
          
      and genAssignments(env, (lefts, rights)) = 
      (* NOTE LLVM doesn't directly support renaming operations, the
         closest you could get is to bitcast the value to the same type,
         since bitcasts are considered noops in llvm. Doing this might be handy
         for debugging, but for now we'll just update env mappings.
       *)
           L.foldr
           (fn ((lhs, rhs), acc) => insertV(acc, lhs, lookupV(acc, rhs)))
           env
           (ListPair.zipEq (lefts, rights))
    
      
      and genConst(env, (lhsVar, lit, ty)) = stubIt env lhsVar
        (* there's a lot of little details here that you need to get right.
           see genLit function in codegen-fn.sml
           you might want to use a LiteralTblFn to handle strings, since
           they must be declared at the top. probably want FloatLit.float
           and IntLit.integer instead of real and IntInf.int, respectively.
           FIXME TODO for now this generates an undef for the rhs. fix thiss *)
        
        
      and genCast(env, (lhsVar, cfgTy, oldVar)) = let
        val llv = lookupV(env, oldVar)
        val targetTy = LT.typeOf cfgTy
        
        val castPair = (LB.toTy llv, targetTy)
        val argPair = (llv, targetTy)
        val newLLVar = LB.cast b (Op.autoCast castPair) argPair
      in
        insertV(env, lhsVar, newLLVar)
      end
      
      and genLabel(env, (lhsVar, rhsLabel)) = let
        val llv = lookupL(env, rhsLabel)
        val ty = LV.typeOf llv
        
        (* this bitcast is a just a trick in LLVM to avoid using an alloca.
           you can only bind to a value the result of an instruction, and clang
           uses an alloca-store-load sequence to do the same thing. we've gotten this
           far without alloca, so we don't do that (even though mem2reg will eliminate the
           stack allocation). *)
        val funcPtr = cast Op.BitCast (LB.fromV(llv), ty)
      in
        insertV(env, lhsVar, funcPtr)
      end
      
      
        (*insertV(env, lhsVar, LB.fromV()*)
      
      
      and genSelect(env, (lhsVar, i, rhsVar)) = let
      (* In CFG, there appears to be an implicit type casting going on with SELECT:
      
t<10CC9>#1 : any
let t<10CCB>#1:[any] = ([any])t<10CC9>
let t<10CCC>#2:[[cont([cont(any/enum(0)),...]/enum(0)),...],[any,any]] = #0 t<10CCB>

another example:

deques<11107>#1:any
let deques<1110A>#1:[any,any] = ([any,any])deques<11107>
let d<1110B>#1:[deque] = #0 deques<1110A>

And this is causing later problems because the results of these two selects have the wrong
type, and later selects from these variables in CFG will hit an error.

Thus, we need to account for this and add a cast. For now I'm keeping it conservative by using BitCast instead of using an autoCast.      

      *)
      
        val implicitCaster = let
                val lhsTy = CFG.Var.typeOf lhsVar
                val rhsTy = CFGTyUtil.select(CFG.Var.typeOf rhsVar, i)
            in
                case (CFGTyUtil.equal(lhsTy, rhsTy), CFGTyUtil.equal(CFGTy.T_Any, rhsTy))
                of (true, _) => (fn x => x) (* do nothing *)
                 | (false, _) => (fn instr => cast Op.BitCast (instr, LT.typeOf lhsTy))
                 (*| _ => raise Fail "did not expect an implicit cast of RHS non-Any ty to some other ty in a select"*)
            end
        
      
      
        val llv = lookupV(env, rhsVar)        
      in
        (case calcAddr i llv
            of SOME addr => insertV(env, lhsVar, implicitCaster (mk Op.Load #[addr]))
             | NONE => ( debug "SELECT" rhsVar llv ; env) (* TODO raise fail instead *)
            (* esac *))
        
      end
      
      and genUpdate(env, (i, ptr, var)) = let
        val llVal = lookupV(env, var)
        val llPtr = lookupV(env, ptr)
        val SOME addr = calcAddr i llPtr
        val newLLVar = mk Op.Store #[addr, llVal]
      in
        env  (* store has an empty result *)
      end
      
      and genAddrOf(env, (lhsVar, i, var)) = let
        val llv = lookupV(env, var)
      in
        (case calcAddr i llv
            of SOME newLLVar => insertV(env, lhsVar, newLLVar)
             | NONE => ( debug "AddrOf" var llv ; stubIt env lhsVar ) (* TODO raise fail instead *)
        (* esac *))
      end
      
      and debug thing rhsVar llv = (print (
          "problem translating " ^ thing ^ " whose argument is CFG var "
          ^ (CV.toString rhsVar) ^ " : " ^ (CFGTyUtil.toString(CFG.Var.typeOf rhsVar)) ^ "\nwhich became LLVM var of type "
          ^ (LT.fullNameOf(LB.toTy llv)) ^ "\n"
          ))
    
      (* below is some gepType testing code
      
      val myVarTy = LT.mkPtr(LT.mkUStruct([LT.mkArray(LT.cnt 10, LT.i32)]))
      val _ = print (LT.fullNameOf myVarTy)
      
      val _ = print ("\n\n0, 0, 1 -> " ^ (LT.fullNameOf((LT.gepType(myVarTy, #[0, 0, 1])))))
      
      val _ = print ("\n\n1 -> " ^ (LT.fullNameOf((LT.gepType(myVarTy, #[1])))))
      
      val _ = print ("\n\n1, 0, 0 -> " ^ (LT.fullNameOf((LT.gepType(myVarTy, #[1, 0, 0])))))
      
      val _ = print "\n---------\n"
      
      

      
      val myVarTy = LT.mkPtr(
                      LT.mkUStruct([
                        LT.mkPtr(
                            LT.mkArray(LT.cnt 40, LT.i32)
                        )
                      ]))
                      
      val _ = print (LT.fullNameOf myVarTy)
      
      (* should fail but doesnt *)
      val _ = print ("\n\n0, 0, 0, 17 -> " ^ (LT.fullNameOf(LT.gepType(myVarTy, #[0, 0, 0, 17]))))
      
      val _ = print ("\n\n0, 0 -> " ^ (LT.fullNameOf((LT.gepType(myVarTy, #[0, 0])))))
      
      
      val _ = print "\n---------\n"
      
      val myVarTy = LT.mkPtr(LT.i32)
                      
      val _ = print (LT.fullNameOf myVarTy)
      
      val _ = print ("\n\n17 -> " ^ (LT.fullNameOf(LT.gepType(myVarTy, #[17]))))
      
      
      val _ = print "\n\n"
      val _ = raise Fail "success"*)
      
            
      (*
        (* initial example *)
        %MyVar = global { [10 x i32] }
        %idx1 = getelementptr { [10 x i32] }, { [10 x i32] }* %MyVar, i64 0, i32 0, i64 1
        %idx2 = getelementptr { [10 x i32] }, { [10 x i32] }* %MyVar, i64 1
        
        (* another example *)
        %MyVar = uninitialized global { [40 x i32 ]* }
        %idx = getelementptr { [40 x i32]* }, { [40 x i32]* }* %, i64 0, i32 0
        %arr = load [40 x i32]** %idx
        %idx = getelementptr [40 x i32], [40 x i32]* %arr, i64 0, i64 17
      *)  
      
      and genAlloc(env, (lhsVar, ty, vars)) = stubIt env lhsVar (* TODO *)
      
      and genGAlloc(env, (lhsVar, ty, vars)) = stubIt env lhsVar (* TODO *)
      
      and genPromote(env, (lhsVar, var)) = stubIt env lhsVar (* TODO *)
      
      and genPrim0(env, prim) = (let
        val llArgs = L.map (fn x => lookupV(env, x)) (PU.varsOf prim)
        val cvtr = OU.fromPrim b prim
      in
        (* lhs for Prim0 so dont update the env. NOTE we're assuming
            no regular prims with a lhs ended up in a Prim0 *)
        (cvtr llArgs ; env) 
      end) handle OU.TODO _ => env (* TODO temp handler*)
      
      and genPrim(env, (lhsVar, prim)) = (let
        val llArgs = L.map (fn x => lookupV(env, x)) (PU.varsOf prim)
        val cvtr = OU.fromPrim b prim
      in
        insertV(env, lhsVar, cvtr llArgs)
      end) handle OU.TODO _ => stubIt env lhsVar (* TODO get rid of this handler
                                                      once all of the primops
                                                      are implemented in fromPrim *)
         
      
      and genCCall(env, (results, func, args)) = (* TODO *)
            L.foldr (fn (r, acc) => stubIt acc r) env results
      
      and genHostVProc(env, lhsVar) = insertV(env, lhsVar, lookupMV(env, MV_Vproc))
      
      (*
      NOTE TODO FIXME (3/13/16)  some fields of a vproc are accessable by other threads.
      a great example of this is the heap limit pointer. LLVM's alias analysis will likely
      assume that the vprocs are not shared or something, and might remove some loads of
      the heap limit pointer (say, in a loop) when it really should not because the value
      is volatile. THUS you should really add the volatile attribute to at _least_ loads,
      if not also for stores, to be correct.
      *)
      
      and genVPLoad(env, (lhsVar, offset, vpVar)) = let
        val lhsTy = (LT.typeOf o CV.typeOf) lhsVar
        val vpLL = lookupV(env, vpVar)
        
        (* now we do the offset & loading sequence *)
        val addr = vpOffset vpLL offset (LT.mkPtr(lhsTy))
        val final = mk Op.Load #[addr] 
      in
        insertV(env, lhsVar, final)
      end
      
      and genVPStore(env, (offset, arg, vpVar)) = let
        val argLL = lookupV(env, arg)
        val argTy = LB.toTy argLL
        val vpLL = lookupV(env, vpVar)    
        
        (* offset and store seq *)
        val addr = vpOffset vpLL offset (LT.mkPtr(argTy))
        val _ = mk Op.Store #[addr, argLL] (* no resulting instr after store *)
      in
        env
      end
      
      and genVPAddr(env, (lhsVar, offset, vpVar)) = let
        val lhsTy = (LT.typeOf o CV.typeOf) lhsVar
        val vpLL = lookupV(env, vpVar)
      in
        insertV(env, lhsVar, vpOffset vpLL offset lhsTy)
      end
      
      
      


    in
        finish(process(initialEnv, body), exit)
    end


  (* testing llvm bb generator *)
    (*
    val t = LB.new(LV.new("entry", LT.labelTy))   
      val intTy = LT.mkInt(LT.cnt 32)
      fun mkInt i = LB.fromC(LB.intC(intTy, i))
      fun mkFloat f = LB.fromC(LB.floatC(LT.floatTy, 0.0))
      val mk = LB.mk t AS.empty
      val mkNSW = LB.mk t (AS.addList(AS.empty, [A.FastMath]))
      val ret = LB.ret t 
      fun fcmp cmp = Op.Fcmp(Op.O(cmp))
      fun icmp cmp = Op.Icmp(Op.S(cmp))

    val bb = ret (mk (icmp(Op.LE)) #[
    (mk Op.Sub #[mkInt 0, mk Op.Add #[mkInt 10, mkInt 200]]),
    (mkInt 0)])
    
    val done = LB.toString bb

    val body = [
      done
    ]
    *)
    

  (* end of Basic Blocks *)

(****** Functions ******)
  
  (* NOTE: this probably should be moved into a new module or something *)
  fun mkFunc (f as C.FUNC { lab, entry, start=(start as C.BLK{ args=cfgArgs, ... }), body }) : string = let
    
    val (mvTys : LT.ty list, cc : (int * C.var) list) = determineCC(entry, cfgArgs)
    
    val pairedMvTys = ListPair.zipEq(L.tabulate(numMachineVals, fn i => i), mvTys)
    
    (* reg vars and the real types *)
    val mvRegs = L.map (fn (i, ty) => let
            val (SOME mv) = IdxMachineVal i
            val (_, name, realTy) = machineInfo mv
        in
            (i, LV.new(name, ty), realTy)
        end) pairedMvTys
        
    val ccRegs = L.map (fn (i, cvar) => let
            val name = CV.nameOf cvar
            val realTy = (LT.typeOf o CV.typeOf) cvar
            val ty = LT.toRegType realTy
        in
            (i, LV.new(name, ty), realTy)
        end) cc
    
    
    (* NEXT now we assign mvRegs :: ccRegs to the jwaCC slots,
       filling in junk slots with "unused" LV's.
       then we pass these two lists to mkBasicBlocks so that 
       a block of bitcasts is produced in the header to fixup 
       the environment. *)
       
    datatype slotTy
     = Used of LV.var
     | NotUsed of LT.ty
       
    (* NOTE the regs must be ordered by slot num *)
    fun assign(nil, nil, res) = L.rev res 
      | assign(slot::rest, nil, res) = assign(rest, nil, (NotUsed (V.sub(LT.jwaCC, slot)))::res)
      | assign(slot::rest, (regs as ((r as (idx, var, _))::rs)), res) =
        if idx = slot 
            then assign(rest, rs, (Used var)::res)
            else assign(rest, regs, (NotUsed (V.sub(LT.jwaCC, slot)))::res)
       
    val slotNums = L.tabulate(V.length LT.jwaCC, fn i => i)
    
    val allRegs = mvRegs @ ccRegs
    
    val _ = if (L.length allRegs) > (L.length slotNums)
            then print ("(llvm-backend) warning: number of live vars across a function call\n"
                        ^ "exceeds the number of registers in jwaCC, thus some values may\n"
                        ^ "be passed via the stack!") else ()
                        
                        (* NOTE this warning is mostly of concern for loops, as
                           each iteration will cause a register spill/reload.
                           If a GC triggers, we'll also have to load these values
                           from the stack just to move them to the heap, and back again
                           upon resuming.
                        *)
    
    val allAssign = assign(slotNums, allRegs, nil)  
    
    val mvs = V.fromList(L.map (fn (_, var, _) => LB.fromV var) mvRegs)
    
    fun mkDecl (Used var) = ((LT.nameOf o LV.typeOf) var) ^ " " ^ (LV.toString var)
      | mkDecl (NotUsed ty) = LT.nameOf ty
    
    fun stringify vars = S.concatWith ", " (L.map mkDecl vars)
    
    val comment = "; comment use to be here \n"
    
    (*val comment = S.concat ["; CFG type: ", CTU.toString cfgTy, "\n",
                            "; LLVM type: ", (stringify  llParamTys), "\n",
                            "; LLVM arity = ", i2s(List.length llParamTys), "\n" ]*)
   
    (* string building code *)
    val linkage = linkageOf lab
    val ccStr = " cc 17 " (* Only available in Kavon's modified version of LLVM. *)
    val llName = (LV.toString o LV.convertLabel) lab
    val decl = [comment, "define ", linkage, ccStr,
                "void ", llName, "(", (stringify  allAssign), ") ",
                stdAttrs(MantiFun), " {\n"]
    
    (* now we setup the environment, we need to make fresh vars for the reg types,
       and map the original parameters to the reg types when we call mk bbelow *)
    
    (* TODO(kavon): the label environment should contain every function in the program *) 
    val body = mkBasicBlocks (ENV{labs=CL.Map.empty, vars=CV.Map.empty, mvs=mvs},
                                start, body, (cc, ccRegs, mvRegs))  

    val total = S.concat (decl @ body @ ["\n}\n\n"])
  in
    total
  end  

  and linkageOf (label) = (case CL.kindOf label
    of C.LK_Func { export = NONE, ... } => "internal"
     | C.LK_Func { export = SOME _, ... } => "external"
     | _ => raise Fail ("linkageOf is only valid for manticore functions.")
     (* end case *))


    (* determines calling conventions. we keep it all localized here
       so we don't mess it up *)
    and determineCC (* returns a ListPair of slots and CFG vars assigned to those slots,
                       and the list of types for machine vals. the indices are defined by 
                       the machine val's index function *)
        (conv : CFG.convention, args : C.var list) : (LT.ty list * (int * C.var) list) = let
            
            val getTy = LT.toRegType o LT.typeOf o C.Var.typeOf
            
            val machineValPadding = 
                List.tabulate(numMachineVals, fn _ => LT.toRegType LT.vprocTy)
            
            fun withPadding convVars = 
                machineValPadding 
                @ (List.map getTy convVars)
            
            fun determineIndices convVars = 
                L.drop((LT.allocateToRegs o withPadding) convVars, numMachineVals)
        in
            (case conv
                of C.StdFunc { clos, ret, exh } => let
                    val convVars = [clos, ret, exh] @ args
                    in
                        (machineValPadding, ListPair.zipEq(determineIndices convVars, convVars))
                    end
                    
                    

                | (C.StdCont { clos } | C.KnownFunc { clos }) => let
                    val convVars = clos :: args
                    in
                        (machineValPadding, ListPair.zipEq(determineIndices convVars, convVars))
                    end
            (* end case *))
      end

(****** end of Functions ******)


  (* Module *)
  
  (* in particular, this just generates essentially a "header" for the LLVM module
     with things such as the datatype layouts, externals, attributes and so on.
     it also initializes the extern info map. *)
  fun mkFunDecls () : string = let

    fun attrOfC (a : CF.attribute) = (case a
          of CF.A_pure => "readonly"
           | CF.A_noreturn => "noreturn"
           (* alloc/malloc attribute in C doesn't seem to translate over to LLVM IR *)
           | _ => ""
          (* end case *)) 

    (* external C function *)
    fun toLLVMDecl (CF.CFun { var, name, retTy, argTys, varArg, attrs }) = let

        val c2ll = LT.nameOf o LT.typeOfC

        val llvmParams = S.concatWith ", " (L.map c2ll argTys)

        val llvmParams = if not varArg
                      then llvmParams
                      else if S.size llvmParams > 0
                        then S.concat [llvmParams, ", ..."]
                        else "..."

        val llvmAttrs = mapSep(attrOfC, [stdAttrs(ExternCFun)], " ", attrs)

        (* record this for translation later *)
        val _ = externInfoAdd(var, name)

      in
        S.concat (["declare ", (c2ll retTy), " @", name, "("
                  , llvmParams, ") "]
                  @ llvmAttrs @ ["\n"])
      end

    val arch = (case Spec.archName
      of "x86_64" => "x86_64-"
       | _ => raise Fail ("Unsupported archicture type: " ^ Spec.archName)
      (* end case *))

    val (targetTriple, dataLayout) = (case Spec.osName
      (* QUESTION: should this be pc-darwin instead, or is the only darwin OS we're referring to OS X? *)
      (* might want to specify OS X version, and ensure this data layout matches our needs *)
      of "darwin" => (arch ^ "apple-macosx", "e-m:o-i64:64-f80:128-n8:16:32:64-S128")
       | "linux" => (arch ^ "pc-linux", "unknown")
       | _ => raise Fail ("Unsupported OS type: " ^ Spec.archName)
      (* end case *))

    val externDecls = S.concat (List.map toLLVMDecl module_externs)

    val header = S.concat [
      "target datalayout = \"", dataLayout, "\"\n",
      "target triple = \"", targetTriple, "\"\n\n",
      externDecls
       ]

    in
      header
    end

  (* end of Module *)




(* Notes:
    
      ordering of declarations only matters in LLVM for types.
        
        so, string constants need to be saved as we generate the module, and then we can
          shove them at the end of processing the functions.

      *)

  (* process the whole module, generating a string for each function and populating the type
     and string literal caches *)
  val funStrings = List.map mkFunc module_code  

in
  ( (* output sequence *)
    
    (* header *)
    pr (S.concat 
        ["; Generated by Manticore\n",
         "; ModuleID = '", Atom.toString module_name, "'"]) ;

    (* types need to go first, because they must be declared before used in functions etc*)
    pr "\n\n; type decls\n\n" ;
    pr (LT.typeDecl()) ;  

    pr "\n\n; externs & target info\n\n" ;
    pr (mkFunDecls ()) ; (* declare extern funs, target triple, and datalayout *)

    pr "\n\n; manticore function defs\n\n" ;
    List.app pr funStrings ;

    pr "\n\n\n\n; ---------------- end of LLVM generation ---------------------- \n\n\n\n" ;
    PrintCFG.output {counts=true, types=true, preds=true} (outS, module) ;
    ()
  )

end

     

end
