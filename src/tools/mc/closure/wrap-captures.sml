(* wrap-captures.sml
 *
 * COPYRIGHT (c) 2017 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * After cont classification for direct-style conversion, we wrap continuation
 * captures so they may be emitted correctly by the code generator. In particular,
 * we perform the following type of expansion in order to turn the definition
 * of an escape continuation into one where the binding location of all
 * uses for that continuation is the parameter of a function that is invoked via
 * callec. Then, the original definition turns into a local continuation of
 * the enclosing function.
 *
 *
 *  fun outerF(.. / retK : cont(t', t'', ...)) =
 *    A
 *    cont k (x : t) = B   <- an Other or Goto cont.
 *    in
 *      C
 *
 *      ===>
 *
 *  fun outerF (.. / retK : cont(t', t'', ...)) =
 *    A
 *    cont k (x : t) = B                                    <-- now classified as a join cont!
 *    in
 *      cont landingPad (arg : any, indicator : int) =    <-- a ret cont
 *       if indicator = regularRet
 *         then throw retK (#1(arg), #2(arg), ...)
 *       else if indicator = escapeThrow
 *         then throw k arg
 *       else if indicator = localThrow1
 *         then throw localCont arg
 *       ...
 *
 *      in
 *        fun manipK (k' : cont(t) / landingPad' : cont(any, int), deadExh) =
 *          cont invokeRetK (a1, a2, ...) =                  <-- a join/ret cont
                let x = alloc(a1, a2, ...)                  <-- only if more than 1 arg
 *              throw landingPad' (x, regularRet)
 *          in
 *          cont invokeLocalK (...) = ... throw landingPad' (..., localThrow1) in
 *            [ C / k -> k', retK -> invokeRetK, localK -> invokeLocalK ]
 *        (* end manipK *)
 *        callec ( manipK / landingPad, deadExh)
 *
 *  The callec construct encapsulates the runtime system manipulation of the
 *  current continuation in accordance to the type of call stack in use.
 *  Callec will allocate the following continuation to represent 'k':
 *
 *  - [ ASM_Resume (1 or 2) | stackPtr (@landingPad) | stackInfo ]
 *    When invoked, this little continuation simply passes the arg its given
 *    to the stack frame pointed to, and sets the appropriate arg register
 *    to indicate where control should resume.
 *
 *  - During translation, within the expression C, any throws must be updated
 *    match the new calling convention. We introduce local cont bindings at the
 *    start of the manip function to simplify this process, since we need to add
 *    an additional fixed argument.
 *
 *
 *
 *)


 (* TODO FIXME

    Consider the following

    cont joinK () = ...
    in
      cont otherK () = ...
      in
        expA   <- contains a throw to joinK

    ===>

    cont joinK () = ...    <-- uh oh, now this is a GotoCont!
    in
      cont otherK () = ...
      in
        cont landingPad () ...
        in
          fun manipK( , landingPad' ) =
            ...
            throw joinK ()   <-- now a Goto throw.

    the solution to this is to ask for the FVs of expA and check for any Join conts
    in that set. For each one, assign to it an integer.
    Then, in the landingPad, have a switch dispatch to these continuations based
    on that integer, and replace all throws to those joinK's with a throw to the landing pad,
    as appropriate. You could introduce sentinel conts in manipK that pick the right integer
    for each one to hide calling convention issues.

    Because this is a rare thing to happen in my benchmarking, i.e., it only showed up
    when I was trying to compile the round-robin scheduler, which has needless uses of
    conts to escape loops, I haven't bothered to update the code below for this case.
    - Kavon (3/19/17)

 *)

 (* NOTE [single-param cont]
   The reason for single parameter conts is that this continuation has unknown call sites.
    By the nature of how these continuations are captured in direct-style, we
    must merge the types of the parameters to the return continuation and
    this continuation so they have the same calling convention (both must return
    to the same basic block in the end, just like setjmp/longjmp).

    We can (and do) eta-expand the throw to the original return cont to match up
    the calling convention with the landing pad. However, we _cannot_ do the
    same for this escape cont, because then the cont we wrapped around the throw
    would be used as a Goto/Other cont, and we're back where we started!
 *)

structure WrapCaptures : sig

    val transform : CPS.module -> CPS.module

  end = struct

    structure C = CPS
    structure CV = C.Var
    structure CTU = CPSTyUtil
    structure VMap = CV.Map
    structure VSet = CV.Set
    structure ST = Stats
    structure L = List
    structure K = ClassifyConts
    structure FV = FreeVars

    (********** Counters for statistics **********)
    val cntExpand = ST.newCounter "wrap-captures:expand"

    (***** environment utils *****)
    datatype environment = E of { sub : cont_kind VMap.map, (* cont substitution map. *)
                                  allLocals : VSet.set (* set of all locally bound conts in the current fun. *)
                                }
        and cont_kind = LocalCont of CV.var * int
                      | EscapeCont of CV.var * int

    fun emptyEnv () = E{ sub = VMap.empty,
                         allLocals = VSet.empty
                       }

    (* utilities for handling local cont set *)
    fun addLocalCont ((E{sub, allLocals}), k) =
        E{sub=sub, allLocals = VSet.add(allLocals, k) }

    fun addLocalConts ((E{sub, allLocals}), ks) =
        E{sub=sub, allLocals = VSet.addList(allLocals, ks) }

    fun resetLocalConts (E{sub, allLocals = dead}) =
        E{sub=sub, allLocals = VSet.empty }

    fun localConts (E{allLocals,...}) = allLocals

    (* finds a substitution in the env *)
    fun lookupKind (E{sub,...}, v) = VMap.find(sub, v)
    and lookupV (x as (_, v)) = (case lookupKind x
        of SOME(LocalCont (newV, _)) => newV
         | SOME(EscapeCont (newV, _)) => newV
         | NONE => v)

    fun insertV (E{sub, allLocals}, var, valu) =
        E{ sub = VMap.insert(sub, var, valu), allLocals=allLocals }

    fun subst env v = lookupV(env, v)

    fun dumpEnv msg env = raise Fail "dumpEnv not implemented"

    (***** end of environment utils *****)


    val indicatorTy = CPSTy.T_Raw(RawTypes.T_Int)

    (****** helper funs to build expressions ******)
    structure MK = struct
        fun fresh(ty, k) = k (CV.new("t", ty))

        fun cast(var, targTy, k) = let
            val lhs = CV.new(CV.nameOf var, targTy)
        in
            C.mkLet([lhs], C.Cast(targTy, var), k lhs)
        end

        fun atLeastOneArg (args, k) =
            if L.null args
            then fresh(CPSTy.T_Any, fn argv =>
                    C.mkLet([argv], C.Const(Literal.unitLit, CPSTy.T_Any),
                        k [argv]))
            else k args


        fun selectAll(tys, tup, k) = let
            fun get (_, [], args) = k (L.rev args)
              | get (i, t::ts, args) =
                    fresh(t, fn a =>
                      C.mkLet([a], C.Select(i, tup), get(i+1, ts, a::args)))
        in
            get(0, tys, [])
        end

        (* this should match up with 'dispatch' below *)
        fun bundle ([], k) = k [] (* NOTE kind of unexpected but okay *)
          (* | bundle ([a], k) = k [a] see NOTE in 'dispatch' *)
          | bundle (args, k) = let (* we need to bundle them up *)
                val allocTy = CPSTy.T_Tuple(false, L.map CV.typeOf args)
                val lhs = CV.new("bundle", allocTy)
              in
                C.mkLet([lhs], C.Alloc(allocTy, args), k [lhs])
              end

        fun dummyExh k = let
            val exhTy = CPSTy.T_Cont([CPSTy.T_Any])
            val exh = CV.new("deadExh", CPSTy.T_Any)
        in
            C.mkLet([exh], C.Const(Literal.unitLit, CPSTy.T_Any),
              cast(exh, exhTy, k))
        end

        fun unitRetk(ty, k) = let
            val retk = CV.new("unitRetk", CPSTy.T_Any)
        in
            C.mkLet([retk], C.Const(Literal.unitLit, CPSTy.T_Any),
              cast(retk, ty, k))
        end

        fun bindInt (i, k) =
            fresh(indicatorTy, fn lhs =>
                C.mkLet([lhs], C.Const(Literal.Int i, indicatorTy),
                    k lhs))

        fun argTysOf cont = (case CV.typeOf cont
            of CPSTy.T_Cont tys => tys
             | _ => raise Fail "not a cont")

    end (* end MK *)

    (****** END OF helper funs to build expressions ******)

    fun start moduleBody = doFun (emptyEnv()) moduleBody

    and doExp (env, C.Exp(ppt, t)) = let
        fun wrap term = C.Exp(ppt, term)
    in
    (case t
        of C.Let (vars, rhs, e) => wrap (C.Let(vars, CPSUtil.mapRHS (subst env) rhs, doExp(env, e)))
         | C.Fun (lambdas, e) => wrap (C.Fun(L.map (doFun env) lambdas, doExp(env, e)))
         | C.If (cond, e1, e2) => wrap (C.If (cond, doExp(env, e1), doExp(env, e2)))
         | C.Switch(var, arms, dflt) => wrap (let
                fun doArm (tag, e) = (tag, doExp(env, e))
                fun doDflt e = doExp(env, e)
             in
                C.Switch(var, L.map doArm arms, Option.map doDflt dflt)
             end)
         | C.Apply (f, args, rets) => (* let
                (* an Apply may change from being in tail position
                   to non-tail due to manipKRetk, which are the only types of retk's
                   in the environment in the case of a substution in an Apply. *)

                val newRetk = ref false

                fun isUnit v = (case CV.kindOf v
                    of C.VK_Let(C.Cast(_, v)) => isUnit v
                     | C.VK_Let(C.Const _) => true
                     | _ => false
                    (* esac *))

                fun substRets (env, [retk, exnk], k) =
                        replaceRetk(env, retk, fn newRetk => k [newRetk, exnk])
                  | substRets (env, [retk], k) =
                        replaceRetk(env, retk, fn newRetk => k [newRetk])

                and replaceRetk (env, oldRetk, k) = (case lookupKind(env, oldRetk)
                    of SOME(EscapeCont _) => raise Fail (CV.toString oldRetk ^ " should not appear as a ret!")
                     | SOME(RetCont newV) => k (newRetk := true ; newV)
                     | NONE =>
                        if not (isUnit oldRetk)
                          then k oldRetk
                          else let val paramRet = getParamRet env in
                                 if inManipScope env
                                     andalso (not (
                                       CPSTyUtil.match(CV.typeOf oldRetk,
                                                       CV.typeOf paramRet)))
                                  (* the type of the unit retk needs to
                                      change to match the enclosing manipK's
                                      return continuation type. *)
                                  then MK.unitRetk(CV.typeOf paramRet,
                                          fn newUnitRK => k newUnitRK)

                                  else k oldRetk
                               end
                     (* esac *))
             in
                substRets(env, rets, fn rets => let
                        val applyExp = wrap (C.Apply(f, L.map (subst env) args, rets))
                    in
                        if !newRetk
                        then (K.setTailApply(applyExp, false) ; applyExp)
                        else applyExp
                    end)
             end *) raise Fail "fixup Apply translation"

         | C.Throw (k, args) => (* let
              val freshArgs = L.map (subst env) args
            in
              case lookupKind (env, k)
                of NONE => wrap(C.Throw(k, freshArgs))
                 | SOME (RetCont newK) => wrap(C.Throw(newK, freshArgs))
                 | SOME (EscapeCont newK) => let
                      val [arg] = freshArgs (* expecting only 1 arg to all escape conts. *)
                      val argTy = CV.typeOf arg
                      val [paramTy] = MK.argTysOf newK
                      val needsBox = not (CTU.isKind (CTU.kindOf argTy) CPSTy.K_BOXED)
                   in
                    if needsBox
                      then MK.bundle(freshArgs, fn bundledArgs =>
                              wrap(C.Throw(newK, bundledArgs)))
                      else wrap(C.Throw(newK, freshArgs))
                    (* DEBUG
                    print (concat["throw to escape ", CV.toString k, " --> ", CV.toString newK, "\n"]) ;
                    print (concat[CTU.toString argTy, " --> ", CTU.toString paramTy, ", needsBox = ", Bool.toString needsBox, "\n\n"]) ;
                    C.Throw(newK, [arg])
                    *)
                   end
            end *) raise Fail "fixup Throw translation"

         | C.Cont (cont as (C.FB{f, params, rets, body}, e)) => wrap (
            case K.kindOfCont f
               of (K.GotoCont | K.OtherCont) =>
                   (* see NOTE [single-param cont] *)
                   if L.length params > 1
                     then raise Fail ("escape cont "
                                     ^ (CV.toString f)
                                     ^ " takes more than 1 parameter!")
                     else ( ST.tick cntExpand ;
                            landingPadCapture env cont )

                | _ => let  val env = addLocalCont(env, f)  in
                          C.Cont(C.FB{f=f,params=params,rets=rets,
                                body = doExp(env, body)}, doExp(env, e))
                      end
              (* end wrap *))
        (* esac *))
    end

    and doFun env (C.FB{f, params, rets, body}) = let
        val env = resetLocalConts env
        val env = addLocalConts (env, rets)
    in
        C.FB{f=f,params=params,rets=rets, body= doExp(env, body) }
    end


    and landingPadCapture env cont = raise Fail "implement landingpadCapture"

(* NOTE old code

    and doesNotReturn env curRets fvs = let
      val curRets = VSet.addList(VSet.empty, curRets)

      (* sanity checks about rets *)
      val allRets = VSet.map (subst env) (getAllRets env)
      val withoutCur = VSet.difference(fvs, curRets)
      val nonLocalRets = VSet.intersection(allRets, withoutCur)
      val () = if VSet.isEmpty nonLocalRets
                then ()
                else let val offender::_ = VSet.listItems nonLocalRets in
                raise Fail (concat [
                    "the return cont ", CV.toString offender,
                    " is thrown to from an enclosing function!"
                  ]) end
    in
      VSet.isEmpty (VSet.intersection(fvs, curRets))
    end

    (* uses a "landing pad" to discern whether the callee
      has invoked the continuation or wants to return
      from the enclosing function. both cases have their
      live values saved on the stack. This is similar to
      setjmp/longjmp.  *)
    and landingPadCapture env (C.FB{f, params, rets, body}, e) = let
           val retk = getRet env
           val paramRet = getParamRet env
           val neverReturns = doesNotReturn env
                                [retk, paramRet]
                                (FV.freeVarsOfExp e)

           (* DEBUG
           val msg = concat ["def of ", CV.toString f,
                  " is followed by exp that ", if neverReturns then "never returns" else "can return",
                  "\n"]
           val _ = dumpEnv msg env
           *)

           val (padFB as C.FB{f=retkWrap,...}) = mkLandingPad(retk, f, neverReturns)

           fun mkManipKBody env (newF, newActiveRetk, manipKRetParam) = let
               val env = (case newActiveRetk
                            of SOME rk => insertV(setRet(env, rk), retk, RetCont rk)
                             | NONE    => env
                             (* end case *))
               val env = insertV(env, f, EscapeCont newF)
               (* val env = setParamRet(env, manipKRetParam) *)
               val env = setManipScope(env, true)
           in
               doExp(env, e)
           end

           val (manipFB as C.FB{f=manipK,...}) = mkManipFun(f, retk, neverReturns, mkManipKBody env)

           val contBody = doExp(env, body)

           (* set/update classifications *)
           val _ = (K.setKind(retkWrap, K.ReturnCont) ; K.setKind(f, K.JoinCont))
        in
           C.Cont(C.FB{f=f,params=params,rets=rets, body=contBody},
               C.mkCont(padFB,
                   C.mkFun([manipFB],
                       MK.dummyExh(fn unitExh =>
                           C.mkCallec(manipK, [retkWrap, unitExh])))))
        end

    (* The tricky part here is that we need to merge the type of the arguments
       to these two continuations so we can longjmp or return to the same block.
       Of course, we do not know all throw sites of an escape cont, so we need a
       uniform calling convention.

       The approach we're taking right now is that the args are always boxed
       in a tuple.

       NOTE:
       Once things are working well, we could start optimizing this by
       avoiding the box for single arity conts. For example:
          1. if both arg kinds are UNIFORM, then the any type works for both
             and only a cast is needed
          2. if both are equal RAW types that will be passed in a GPR,
             then nothing special is needed. Floats would need a box.
    *)
    and mkLandingPad (retk, kont, neverReturns) = let

        val padTy = if neverReturns
                    then CPSTy.T_Cont([CPSTy.T_Any])
                    else CPSTy.T_Cont([CPSTy.T_Any, indicatorTy])

        val padVar = CV.new("setjmpLandingPad", padTy)

        val boolParam = CV.new("regularRet", indicatorTy)

        (* NOTE: always assuming the use of a box right now *)
        val valParam = CV.new("arg", CPSTy.T_Any)

        fun branch(trueExp, falseExp) =
            MK.fresh(indicatorTy, fn fals =>
              C.mkLet([fals], C.Const(falseVal, indicatorTy),
                C.mkIf(Prim.I32NEq(boolParam, fals), trueExp, falseExp)))

        (* this should match up with MK.bundle !! *)
        fun dispatch cont = (case MK.argTysOf cont
            of [] => raise Fail "no-arg cont?" (* C.mkThrow(cont, []) (* weird but okay i guess *) *)

             | [ty] => if CTU.isKind CPSTy.K_UNIFORM (CTU.kindOf ty)
                        (* we can just do a cast: any => ty *)
                        then MK.cast(valParam, ty, fn arg => C.mkThrow(cont, [arg]))
                        (* it was boxed, so unbox it *)
                        else unpack cont [ty]
             (* esac *))

        and unpack cont tys = MK.cast(valParam, CPSTy.T_Tuple(false, tys), fn tup =>
                                MK.selectAll(tys, tup, fn args =>
                                  C.mkThrow(cont, args)))

    in
      if neverReturns

      then C.FB{f = padVar, params = [valParam], rets = [],
              body = dispatch kont
              }

      else C.FB{f = padVar, params = [valParam, boolParam], rets = [],
              body = branch(dispatch retk, dispatch kont)
              }

    end

    (* the reason manipK takes an exh that will be unused is because it will use
       the standard calling convention (its caller is actually an unknown fun). *)
    and mkManipFun(origLetCont, origRetk, neverReturns, k) = let
        val contAny = CPSTy.T_Cont([CPSTy.T_Any])
        val retkTy = if neverReturns
                      then CPSTy.T_Cont([CPSTy.T_Any])
                      else CPSTy.T_Cont([CPSTy.T_Any, indicatorTy])

        val contP = CV.copy origLetCont

        (* NOTE: less-optimial type *)
        val _ = CV.setType (contP, contAny)

        val retkP = CV.new("landingPadK", retkTy)
        val exnP = CV.new("deadExnK", contAny)

        val num = Int.toString(ST.count cntExpand) (* aids debugging *)
        val fname = CV.new("manipK" ^ num, CPSTy.T_Fun([CV.typeOf contP], [retkTy, contAny]))

        (* set kind. also need to set contexts since this is a ParamCont *)
        val _ = (K.setContextOfThrow(retkP, VSet.singleton fname) ;
                 K.setContextOfThrow(contP, VSet.singleton fname))
                 (* TODO: more accurately:
                        contextsOf(contP) :=
                            if enclosingFunOf(origLetCont) in contextsOf(origLetCont)
                                then union({ fname },
                                        contextsOf(origLetCont) \ { enclosingFunOf(origLetCont) })
                                else contextsOf(origLetCont)

                    not really critical though since closure conversion doesn't care if
                    its a non-ret param. We just have to have at least one context that
                    tells closure conversion it's not a ret param.
                  *)

        fun mkInvokeRet k = let
            (* build the invoke return cont *)
            val invokeParamTys = MK.argTysOf origRetk
            val invokeRet = CV.new("invokeRetk", CPSTy.T_Cont invokeParamTys)
            val invokeParams = L.map (fn ty => CV.new("param", ty)) invokeParamTys
        in
        (  K.setKind(invokeRet, K.JoinCont) ;
            C.mkCont(C.FB {
                f = invokeRet,
                params = invokeParams,
                rets = [],
                body = MK.bundle(invokeParams, fn newArgs =>
                         MK.atLeastOneArg(newArgs, fn paddedArgs =>
                           MK.bindTrue(fn tru =>
                             C.mkThrow(retkP, paddedArgs @ [tru]))))},
                k invokeRet)
          )
        end

    in
        C.FB {
            f = fname,
            params = [contP],
            rets = [retkP, exnP],
            body = if neverReturns
                    then k (contP, NONE, retkP)
                    else mkInvokeRet(fn invokeRet => k (contP, SOME invokeRet, retkP))
        }
    end
*)

    (* UnifyNonRetSigs and ClassifyConts must be run before this transform. *)
    fun transform (m as C.MODULE{name, externs, body}) =
        if not(Controls.get BasicControl.direct)
        then m
        else let
            val m = C.MODULE{name=name,externs=externs,body = start body }
            val _ = CPSCensus.census m
        in
            m
        end

  end
