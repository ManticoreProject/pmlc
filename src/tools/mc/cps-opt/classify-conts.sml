(* classify-conts.sml
 *
 * COPYRIGHT (c) 2016 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *)

structure ClassifyConts : sig

    val analyze : CPS.module -> unit

    val clear : CPS.module -> unit

  (* the different kinds of continuations *)
    datatype cont_kind
      = JoinCont        (* a join-point; all uses are throws that are in the
                         * same function as the binding site of the
                         * continuation. can be mapped as a basic block.
                         *)

      | GotoCont        (* similar to a join-point; throw sites are all known, but
                         * at least one site occurs in within another function
                         * or an OtherCont.
                         * this cont is mapped as a function instead of a block.
                         *)

      | ReturnCont      (* passed as a return continuation to another function
                         *)

      | ExnCont         (* passed as an exception handler to another function
                         *)

      | ParamCont       (* bound as parameter (other than return or exception) *)

      | OtherCont       (* continuation that escapes in some-other way (i.e.,
                         * a first-class continuation)
                         *)

    val kindToString : cont_kind -> string

  (* return the kind of  a continuation *)
    val kindOfCont : CPS.var -> cont_kind

    val setKind : (CPS.var * cont_kind) -> unit

  (* Given a continuation var, returns the set of all immediately enclosing functions
     from which a throw to the cont was found. *)
    val contextOfThrow : CPS.var -> CPS.Var.Set.set

    val setContextOfThrow : (CPS.var * CPS.Var.Set.set) -> unit

    (* helper for contextOfThrow. will check the rets of the lambda to see if
       the given var matches one of those. *)
    val checkRets : (CPS.var * CPS.lambda) -> cont_kind option

  (* is k a join continuation?  This returns false when classification is
   * disabled.
   *)
    val isJoinCont : CPS.var -> bool

    val isReturnCont : CPS.var -> bool

    (* also checks the binding if it is a ParamCont to see if it's in the retk position. *)
    val isReturnThrow : CPS.var -> bool

    val isTailApply : CPS.exp -> bool

    val setTailApply : (CPS.exp * bool) -> unit

  end = struct

    structure C = CPS
    structure CV = CPS.Var
    structure ST = Stats
    structure CFA = CFACPS

    (* controls *)
    val enableFlg = ref true
    val usingDS = ref false

    val () = List.app (fn ctl => ControlRegistry.register CPSOptControls.registry {
              ctl = Controls.stringControl ControlUtil.Cvt.bool ctl,
              envName = NONE
            }) [
              Controls.control {
                  ctl = enableFlg,
                  name = "enable-join-opt",
                  pri = [0, 1],
                  obscurity = 0,
                  help = "enable optimization of join continuations"
                }
            ]


    type context = C.var        (* function or continuation that encloses
                                 * the expression in question.
                                 *)

  (* the different kinds of continuations *)
    datatype cont_kind
      = JoinCont        (* a join-point; all uses are throws that are in the
                         * same function as the binding site of the
                         * continuation. can be mapped as a basic block.
                         *)

      | GotoCont        (* similar to a join-point; throw sites are all known, but
                         * at least one site occurs in within another function.
                         * this cont is mapped as a function instead of a block.
                         *)

      | ReturnCont      (* passed as a return continuation to another function
                         *)

      | ExnCont         (* passed as an exception handler to another function
                         *)

      | ParamCont       (* bound as parameter to a lambda. *)

      | OtherCont       (* continuation that escapes in some-other way (i.e.,
                         * a first-class continuation)
                         *)

    fun kindToString JoinCont = "JoinCont"
      | kindToString ReturnCont = "ReturnCont"
      | kindToString ExnCont = "ExnCont"
      | kindToString ParamCont = "ParamCont"
      | kindToString GotoCont = "GotoCont"
      | kindToString OtherCont = "OtherCont"

  (********** Counters for statistics **********)
    val cntJoinCont     = ST.newCounter "classify-conts:join-cont"
    val cntReturnCont   = ST.newCounter "classify-conts:return-cont"
    val cntExnCont      = ST.newCounter "classify-conts:exn-cont"
    val cntOtherCont    = ST.newCounter "classify-conts:other-cont"
    val cntGotoCont     = ST.newCounter "classify-conts:goto-cont"
    val cntTotalCont    = ST.newCounter "classify-conts:total-conts"

  (* the outer context of a letcont-bound variable *)
    local
      val {peekFn, setFn : C.var * context -> unit, clrFn : C.var -> unit, ...} =
            CV.newProp (fn _ => raise Fail "nesting")
    in
    val getOuter = peekFn
    val setOuter = setFn
    val clearOuter = clrFn
    end

  (* track the use sites of a possible join-point continuation *)
    local
      val {peekFn, setFn : C.var * context list ref -> unit, clrFn, ...} =
            CV.newProp (fn _ => ref[])
    in
    fun initUse k = setFn(k, ref[])
    fun trackUses k = (case peekFn k
        of NONE => initUse k
         | _ => ()
         (* end case *))
    fun addUse (outer, k) = (case peekFn k
           of NONE => ()
            | SOME r => r := outer :: !r
          (* end case *))
    fun clrUses k = clrFn k
    fun usesOf k = (case peekFn k
           of SOME xs => !xs
            | NONE => []
          (* end case *))
    end

  (* track the kind of a bound continuation *)
    local
      val {peekFn, setFn : C.var * cont_kind -> unit, clrFn : C.var -> unit, ...} =
            CV.newProp (fn _ => raise Fail "cont kind")
    in
  (* return the kind of  a continuation *)
    fun kindOf k = (case peekFn k
           of NONE => OtherCont
            | SOME kind => kind
          (* end case *))
    fun isJoin k = (case kindOf k
          of JoinCont => true
           | _ => false
           (* end case *))
    fun markAsJoin k = (setFn(k, JoinCont); initUse k)
    fun markAsReturn k = (setFn(k, ReturnCont); trackUses k)
    fun markAsExn k = setFn(k, ExnCont)
    fun markAsGoto k = (setFn(k, GotoCont); clrUses k)
    fun markAsOther k = (case peekFn k
           of SOME OtherCont => ()
            | _ => (setFn(k, OtherCont); clrUses k)
          (* end case *))

    val setKind = setFn
    fun clearKind k = (clrFn k; clrUses k)
    end

    (* check/mark whether an Apply is in a tail position *)
    local
        val {getFn : ProgPt.ppt -> bool, setFn : ProgPt.ppt * bool -> unit}
            = ProgPt.newFlag()
    in
        val checkTail = getFn
        val markTail = setFn
        fun clearTail ppt = markTail(ppt, false) (* no clrFn for a flag *)
    end

    (* Mark throws with their immediately enclosing function. This will allow closure
       conversion to determine whether a throw to a Return continuation is a function
       return or just a jump. Example:

        fun x () =
            cont foo () =
                ...
            (* end foo *)
            if ...
                then apply bar {retk = foo, ...}
                else throw foo ()

       Here, foo is marked as a return continuation, so foo will be a basic block within x,
       but foo also has a throw to it that within x, but this is _not_ a return throw, but merely
       a jump to a continuation that happens to marked as a return continuation.
    *)
    local
        val {getFn, setFn : C.var * CV.Set.set -> unit, clrFn : C.var -> unit, ...} =
              CV.newProp (fn _ => CV.Set.empty)
    in
        val contextOfThrow = getFn
        val setContextOfThrow = setFn
        val clearContextOfThrow = clrFn
        fun addThrowContext (k, CPS.FB{f,...}) = setContextOfThrow(k, CV.Set.add(contextOfThrow k, f))
    end

  (* given a binding context for a continuation, check uses to see
   * if they are in the same function environment.
   *)
    fun checkUse outer = let
          fun chkCPS k = CV.same(outer, k)
                orelse (case kindOf k
                   of JoinCont => (case getOuter k
                         of NONE => false
                          | SOME k' => chkCPS k'
                        (* end case *))
                    | _ => false
                  (* end case *))

          fun chkDS k = CV.same(outer, k)

          in
            if !usingDS then chkDS else chkCPS
          end


    (* This use to check CFA info to find the value of K. Turns out this was not needed or buggy.
       yet it remains here. TODO: clean up uses of this! *)
    fun actualCont k = k

    (* climbs the context, if necessary, to find the immediately enclosing function. *)
    fun enclosingFun outer = (case CV.kindOf outer
        of C.VK_Fun fb => SOME fb
         | C.VK_Cont(C.FB{ f , ...}) => (case getOuter f
             of SOME newOuter => enclosingFun newOuter
              | _ => NONE
             (* esac *))
        | _ => NONE
    (* esac *))

    fun analExp (outer, C.Exp(ppt, t)) = (case t
            of C.Let (_, _, e) => analExp (outer, e)

            | C.Fun(fbs, e) => let
                fun doFB (C.FB{f, body, ...}) = analExp (f, body)
                in
                  List.app doFB fbs;
                  analExp (outer, e)
                end

            | C.Cont(C.FB{f, body, ...}, e) => let
                (* JoinCont iff
                     not escaping
                     AND not thrown to recursively (in its own body)
                     AND all uses occur within the same enclosing function

                   Return/Exception Cont iff
                     not escaping
                     AND passed as such a continuation in at least one Apply
                     AND all uses occur within the same enclosing function

                   GotoCont iff
                     not escaping
                     AND not a return or exception cont

                   OtherCont anything else
                 *)

            in (
                (* initialize properties for this continuation *)
                setOuter (f, outer);

                (* if CFA says it's not escaping, conservatively mark it
                    as a Join for now. *)
                if CFA.isEscaping f
                    then markAsOther f
                    else markAsJoin f;

                (* analyse its body *)
                if !usingDS (* for DS, the only binding context we care about are funcs *)
                  then analExp (outer, body)
                  else analExp (f, body);

                (* analyze the expression in which it is scoped *)
                analExp (outer, e);

                if Controls.get CPSOptControls.debug then
                print (concat (["ClassifyConts:\t\tk = " ^ CV.toString f, "; uses = ",
                          (String.concatWith ", " (map CV.toString (usesOf f))),
                        "; outer = ", CV.toString outer, "\n"]))
                else ();

                (* determine whether the join/return is actually a goto *)
                (case (kindOf f, !usingDS)
                  of ((JoinCont, _) | (ReturnCont, true)) =>
                    if List.all (checkUse outer) (usesOf f)
                        then ()
                        else markAsGoto f
                   | _ => ());

                if Controls.get CPSOptControls.debug then
                print(concat[
                      "ClassifyConts: kindOf(", CV.toString f, ") = ",
                      kindToString(kindOf f), "\n"
                    ])
                  else ()
                  ;

              (* collect statistics in one place *)
              ST.tick cntTotalCont;

              (case kindOf f
                of JoinCont => ST.tick cntJoinCont
                 | ReturnCont => ST.tick cntReturnCont
                 | OtherCont => ST.tick cntOtherCont
                 | ExnCont => ST.tick cntExnCont
                 | GotoCont => ST.tick cntGotoCont
              (* esac *))
              )
            end

            | C.If(_, e1, e2) => (analExp(outer, e1); analExp(outer, e2))
            | C.Switch(_, cases, dflt) => (
                List.app (fn (_, e) => analExp(outer, e)) cases;
                Option.app (fn e => analExp(outer, e)) dflt)

            | C.Apply(_, args, rets) => let

                (* we mark the actual cont *)
                val cfaRets = List.map actualCont rets
                val _ = (case cfaRets
                            of [retk, exnk] => (markAsExn exnk ; markAsReturn retk)
                             | [retk] => (markAsReturn retk)
                             | _ => raise Fail "an apply with unexpected rets"
                        (* esac *))

                (*  mark any conts in the arg list as Other, since CFA's
                    definition of escaping is different from ours, i.e.,
                    passing a cont to a known function as an arg is considered
                    escaping for us. *)
                val _ = List.app markAsOther args

                (* now we check whether it's a tail call by comparing the retk param
                   with what is passed in this apply. *)
                val retk :: _ = rets
                val SOME encl = enclosingFun outer
                val SOME enclRet = CPSUtil.getRetK encl

                (* we're looking to see if v originates from a constant, modulo casts.
                   this is a very specific pattern generated by an optimization.

                   TODO Ideally, we'd be able to ask CFA if it is a constant value to
                   potentially get a more robust answer for this.
                *)
                fun isConst v = (case CV.kindOf v
                    of C.VK_Let(C.Cast(_, v)) => isConst v
                     | C.VK_Let(C.Const _) => true
                     | _ => false
                    (* esac *))
            in
                (* an Apply is a tail call if

                1. the enclosing ret cont is the same as the one passed to the function
                2. the return continuation being passed is "unit", aka, the function does
                   not return normally (some CPS optimization will do this).

                 *)
                markTail(ppt, CV.same(enclRet, retk) orelse isConst retk)
            end

            | C.Throw(k, args) => let
                (* we check CFA information to determine if k is an alias for some Cont,
                   and add the use to the actual Cont and not the alias.

                   this may happen if a Cont is casted/rebound, which can be introduced
                   after arity raising. *)
                     val _ = List.app markAsOther args (* see App case *)
                     val SOME encl = enclosingFun outer
                   in
                    addUse (outer, actualCont k) ; addThrowContext (k, encl)
                   end

            | C.Callec  (f, args) =>
              (* NOTE: we're assuming the exn cont is unit, so its classification
                 is irrelevant *)
                List.app markAsReturn args



          (* end case *))

    fun analyze (C.MODULE{body=C.FB{f, body, ...}, ...}) =
        (usingDS := (Controls.get BasicControl.direct) ; analExp (f, body))

  (* return the kind of a continuation *)
    fun kindOfCont k = (case CV.kindOf k
           of C.VK_Cont _ => kindOf k
            | C.VK_Param _ => ParamCont
            | _ => OtherCont
          (* end case *))

    and checkRets (k, C.FB{ rets = [retk] , ...}) =
            if CV.same(k, retk) then SOME ReturnCont else NONE
      | checkRets (k, C.FB{ rets = [retk, exnk] , ...}) =
            if CV.same(k, retk) then SOME ReturnCont
            else if CV.same(k, exnk) then SOME ExnCont
            else NONE
      | checkRets _ = NONE

  (* is k a join continuation? if the optimization is disabled, we always say no *)
    fun isJoinCont k = !enableFlg
          andalso (case (kindOfCont o actualCont) k
             of JoinCont => true
              | _ => false
            (* end case *))

  (* is k a return continuation? *)
    fun isReturnCont k =
        (case (kindOfCont o actualCont) k
            of ReturnCont => true
             | _ => false
            (* esac *))

    fun isReturnThrow k =
        (case (kindOfCont o actualCont) k
            of ReturnCont => true
             | ParamCont => (case CV.kindOf k
                 of CPS.VK_Param fb => (case checkRets (k, fb)
                     of SOME ReturnCont => true
                      | _ => false
                      (* esac *))
                  | _ => false
                  (* esac *))
             | _ => false
            (* esac *))


    fun isTailApply (C.Exp(ppt, C.Apply _)) = checkTail ppt

    fun setTailApply (C.Exp(ppt, C.Apply _), status) = markTail (ppt, status)


    fun clear (C.MODULE{body=C.FB{f, body, ...}, ...}) =
        (usingDS := (Controls.get BasicControl.direct) ; clearExp f body)

    and clearExp outer (C.Exp(ppt, t)) = (case t
            of C.Let (_, _, e) => clearExp outer e
            | C.Fun(fbs, e) => let
                fun doFB (C.FB{f, body, ...}) = clearExp f body
                in
                  List.app doFB fbs;
                  clearExp outer e
                end

            | C.Cont(C.FB{f, body, ...}, e) => (
                clearOuter f;
                clearKind f;
                clearExp f body
                )

            | C.If(_, e1, e2) => (clearExp outer e1; clearExp outer e2)
            | C.Switch(_, cases, dflt) => (
                List.app (fn (_, e) => clearExp outer e) cases;
                Option.app (fn e => clearExp outer e) dflt)

            | C.Apply(_, args, rets) => let
                val cfaRets = List.map actualCont rets
            in
                (case cfaRets
                    of [retk, exnk] => (clearKind exnk ; clearKind retk)
                     | [retk] => (clearKind retk)
                     | _ => raise Fail "an apply with unexpected rets"
                (* esac *));
                List.app clearKind args;
                clearTail ppt
            end

            | C.Throw(k, args) =>
              ( clrUses outer;
                clearContextOfThrow k
              )

            | C.Callec(f, args) =>
                List.app clearKind args



          (* end case *))
  end
