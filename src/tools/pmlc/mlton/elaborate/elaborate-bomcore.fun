functor ElaborateBOMCore(S: ELABORATE_BOMCORE_STRUCTS) = struct
  open S

  structure BOM = Ast.BOM

  type funtype = {
    dom: CoreBOM.BOMType.t list,
    cont: CoreBOM.BOMType.t list,
    rng: CoreBOM.BOMType.t list
  }

  val badValId = "unbound value identifier"

  fun app3 f (x, y, z) = (f x, f y, f z)
  fun error (getRegion, getLayout, errorVal, element) msg =
    (Control.error (getRegion element, getLayout element, Layout.str msg)
    ; errorVal)
  fun check (error: string -> 'b) (x: 'a option, msg: string) (f: 'a -> 'b) =
    case x of
      SOME y => f y
    | NONE => error msg

  fun elaborateBOMType (astTy: BOM.BOMType.t,
            tyEnvs as {env, bomEnv}): CoreBOM.BOMType.t =
    let
      val error: string -> CoreBOM.BOMType.t =
        error (BOM.BOMType.region, BOM.BOMType.layout,
          CoreBOM.BOMType.Error,
          astTy)
      (* Need to put whole body here to get around value restriction *)
      fun check (x: 'a option, msg: string) (f: 'a -> CoreBOM.BOMType.t) =
        case x of
          SOME y => f y
        | NONE => error  msg
      fun doElaborate ty = elaborateBOMType (ty, tyEnvs)
      (* val wrappedElaborate = CoreBOM.BOMType.wrapTuple o map (fn ty => *)
      (* elaborateBOMType (ty, tyEnvs)) *)

      fun defnArityMatches (input as (defn, tyArgs)) =
        if (BOMEnv.TypeDefn.arity defn) = (length tyArgs) then
          SOME input
        else
          NONE

      fun recordLabelsOkay fields =
        let
          fun fieldToIndex field =
            case field of
              BOM.Field.Immutable (index, _) => index
            | BOM.Field.Mutable (index, _) => index

          (* TODO: make into a fold *)
          fun loop (labels, lastLabel) =
            case labels of
              l::ls =>
                if l > lastLabel then
                  loop (ls, l)
                else
                  false
            | [] => true

          val _ = print (
            String.concat (map (Layout.toString o BOM.Field.layout)
              fields))
        in
          if loop (map (fieldToIndex o BOM.Field.node) fields,
            IntInf.fromInt ~1)
          then
            SOME fields
          else
            NONE
        end

    in
      case BOM.BOMType.node astTy of
        BOM.BOMType.Param tyParam =>
          check
            (BOMEnv.TyParamEnv.lookup (bomEnv, tyParam), "unbound typaram")
            (fn tyParam => CoreBOM.BOMType.Param tyParam)
      | BOM.BOMType.Tuple tys =>
          CoreBOM.BOMType.Tuple (map (fn (m, ty) => (m, doElaborate ty)) tys)
      | BOM.BOMType.Fun funTys =>
          CoreBOM.BOMType.Fun (let
            val (dom, cont, rng) = app3 (map doElaborate) funTys
          in
            {dom=dom, cont=cont, rng=rng}
          end)
      | BOM.BOMType.Any => CoreBOM.BOMType.Any
      | BOM.BOMType.VProc => CoreBOM.BOMType.VProc
      | BOM.BOMType.Cont maybeTyArgs =>
          CoreBOM.BOMType.Cont (map doElaborate maybeTyArgs)
      | BOM.BOMType.Addr ty =>
          CoreBOM.BOMType.Addr (doElaborate ty)
      | BOM.BOMType.Raw ty => CoreBOM.BOMType.Raw (
          CoreBOM.RawTy.fromAst ty)
      | BOM.BOMType.TyCon (longTyId, maybeTyArgs) =>
          let
            val tyArgs = map doElaborate maybeTyArgs
            val tyId = CoreBOM.TyId.fromLongId longTyId
          in
            check
             (BOMEnv.TyEnv.lookup (bomEnv, tyId), "undefined type")
             (fn defn =>
               check
                 (BOMEnv.TypeDefn.applyToArgs (defn, tyArgs), "arity mismatch")
                  (fn x => x))
          end
      | BOM.BOMType.Record fields =>
          check
            (recordLabelsOkay fields, "labels must be strictly increasing")
            (fn fields => CoreBOM.BOMType.Record (map (fn field' =>
              elaborateField (field', tyEnvs)) fields))
      | BOM.BOMType.Exn => CoreBOM.BOMType.Exn
    (* FIXME: need to add exn, others *)
    end
  and elaborateField (astField: BOM.Field.t,
     tyEnvs as {env = env:Env.t, bomEnv = bomEnv: BOMEnv.t}): CoreBOM.Field.t =
    let
      val (constructor, index, astTy) =
        case BOM.Field.node astField of
          BOM.Field.Immutable (index, astTy) =>
            (CoreBOM.Field.Immutable, index, astTy)
        | BOM.Field.Mutable (index, astTy) =>
            (CoreBOM.Field.Mutable, index, astTy)
    in
      constructor (index, elaborateBOMType (astTy, tyEnvs))
    end

  fun extendEnvForTyParams (bomEnv: BOMEnv.t, tyParams: BOM.TyParam.t list) =
    foldl
      (fn (tyP: BOM.TyParam.t, bEnv)
        => BOMEnv.TyParamEnv.extend (bEnv, tyP))
      bomEnv
      tyParams

  (* fun extendEnvForTyParams (bomEnv, maybeTyParams) = *)
  (*   extendEnvForTyParams (bomEnv, CoreBOM.TyParam.flattenFromAst maybeTyParams) *)

  fun checkValArity (valId, ty, params, error): CoreBOM.Val.t =
    if (CoreBOM.BOMType.arity ty) = (length params) then
      CoreBOM.Val.new (valId, ty, params)
    else
      error "arity mismatch"


  fun varPatToTy (pat, tyEnvs) =
    let
      val error = error (BOM.VarPat.region, BOM.VarPat.layout,
        CoreBOM.BOMType.Error, pat)
      val check = check error
      val maybeTy =
        case BOM.VarPat.node pat of
          BOM.VarPat.Var (id, maybeTy) => maybeTy
        | BOM.VarPat.Wild maybeTy => maybeTy
    in
      check
        (maybeTy, "varpat missing type annotation")
        (fn ty => elaborateBOMType (ty, tyEnvs))
    end

  fun extendEnvForFun (funDef: BOM.FunDef.t,
      tyEnvs as {env = env:Env.t, bomEnv = bomEnv: BOMEnv.t}) =
    let
      val BOM.FunDef.Def (
          _, id, maybeTyParams, domPats, contPats, rngTys, _) =
        BOM.FunDef.node funDef
      val envWithTyParams = extendEnvForTyParams (bomEnv, maybeTyParams)
      val tyEnvs' = {env = env, bomEnv = envWithTyParams}
      fun patsToTys pats =
        map (fn pat => varPatToTy (pat, tyEnvs')) pats
      val domTys = patsToTys domPats
      val contTys = patsToTys contPats
      val rngTys' = map (fn ty => elaborateBOMType (ty, tyEnvs')) rngTys
      val funTy = {
          dom = domTys,
          cont = contTys,
          rng = rngTys'
        }
      val valId = CoreBOM.ValId.fromBOMId id
      val newVal = checkValArity (valId, CoreBOM.BOMType.Fun funTy,
        BOMEnv.TyParamEnv.getParams envWithTyParams, error (
          BOM.FunDef.region, BOM.FunDef.layout, CoreBOM.Val.error,
          funDef))
    in
      ({
        env = env,
        bomEnv = BOMEnv.ValEnv.extend (envWithTyParams, valId, newVal)
      }, newVal)
    end

  fun elaborateLiteral (literal, ctx): CoreBOM.Literal.t =
    case BOM.Literal.node literal of
      BOM.Literal.PosInt int => BOMEnv.Context.newInt (ctx, int)
    | BOM.Literal.Float float => BOMEnv.Context.newFloat (ctx, float)
    | _ => raise Fail "not implemented"

  fun lookupValId (checkForErrorVal, bomEnv, valId) =
    checkForErrorVal CoreBOM.Exp.error (BOMEnv.ValEnv.lookup (bomEnv, valId),
    "unbound value identifier")

  fun elaborateFunDefs (funDefs, tyEnvs as {env, bomEnv}) =
    let
      val (envWithFns, funVals) =
        foldr (fn (funDef, (oldEnv, oldVals)) =>
            let
              val (newEnv, newVal) = extendEnvForFun (funDef, oldEnv)
            in
              (newEnv, newVal::oldVals)
            end) (tyEnvs, []) funDefs

      val funDefs' = ListPair.map
        (fn (funDef, funVal) => elaborateFunDef (funDef, funVal, envWithFns))
        (funDefs, funVals)
    in
      (envWithFns, funDefs')
    end

  and elaborateFunDef (funDef: BOM.FunDef.t, funVal: CoreBOM.Val.t,
      tyEnvs as {env, bomEnv}) =
    let
        (* TODO: find the appropriate error value here *)
      val check = check (error (BOM.FunDef.region, BOM.FunDef.layout,
        [CoreBOM.BOMType.Error], funDef))
      val CoreBOM.BOMType.Fun {dom, cont, rng} = CoreBOM.Val.typeOf funVal
      val BOM.FunDef.Def (maybeAttrs, _, _, domPats, contPats, _, exp) =
        BOM.FunDef.node funDef
      (* elaborate the arguments and put them in the environment *)
      fun extendEnvForVarPats (pats, tys, bomEnv) =
        bindVarPats (pats, tys, {env = env, bomEnv = bomEnv})

      val (newEnv, domVals) = extendEnvForVarPats (domPats, dom, bomEnv)
      val (newEnv', contVals) = extendEnvForVarPats (contPats, cont, newEnv)
      val bodyExp = elaborateExp (exp, {env = env, bomEnv = newEnv'})
      val returnTy = check (CoreBOM.BOMType.equals' (CoreBOM.Exp.typeOf bodyExp,
         rng), "function body doesn't agree with range type") (fn x => x)
    in
     (* TODO: handle noreturn *)
     CoreBOM.FunDef.Def (CoreBOM.Attr.flattenFromAst maybeAttrs, funVal,
       domVals, contVals, returnTy, bodyExp)
    end

  and elaborateSimpleExp (sExp, ctx, tyEnvs as {env, bomEnv}) =
    let
      fun checkForErrorVal errorVal = check (error (BOM.SimpleExp.region,
        BOM.SimpleExp.layout, errorVal, sExp))
      val checkVal = checkForErrorVal CoreBOM.Val.error
      val checkTy = checkForErrorVal CoreBOM.BOMType.Error
      val checkExp = checkForErrorVal CoreBOM.Exp.error
      val checkSExp = checkForErrorVal CoreBOM.SimpleExp.error

      (* check that the argument simple exps match the domain ty and
      return an Alloc exp node with type rng if they do *)
      fun elaborateTupleExp (dom, rng, argument, conVal) =
        let
          (* TODO: handle noreturn correctly *)
          val argumentExp = elaborateSimpleExp (argument, ctx, tyEnvs)
          val argumentTy = CoreBOM.SimpleExp.typeOf argumentExp
        in
          checkSExp (CoreBOM.BOMType.equal' (dom, argumentTy),
            "invalid constructor argument")
         (* todo: typarams? *)
          (fn _  => CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.AllocId (conVal,
            argumentExp), rng))
        end
      fun elaborateVpExp (index, procExp) =
        (* TODO: do something useful with the index *)
        let
          val exp = elaborateSimpleExp (procExp, ctx, tyEnvs)
        in
          checkSExp (CoreBOM.BOMType.equal' (CoreBOM.SimpleExp.typeOf exp,
            CoreBOM.BOMType.VProc),
            "argument to vproc operation must be a vproc")
          (fn _ => exp)
        end

      (* FIXME: refactor this to split out cases cleanly *)
      fun elaborateRecordSExp (index, recordSExp, maybeStoreSExp) =
        let
        (* make sure recordSExp evaluates to a record *)
          val recordSExp' = elaborateSimpleExp (recordSExp, ctx, tyEnvs)

          val fieldTys = checkForErrorVal []
            ((case CoreBOM.SimpleExp.typeOf recordSExp' of
              CoreBOM.BOMType.Record fields => SOME fields
            | _ => NONE),
           (* TODO: phrase this better *)
            "argument to index access expression is not a record") (fn x => x)

          (* make sure the record is defined at the specified index *)
          val fieldTy = checkForErrorVal CoreBOM.Field.bogus
            (List.find (fn fieldTy => CoreBOM.Field.index fieldTy = index)
              fieldTys, "no such index") (fn x => x)

          (* if the rhs is a store expression, find out the type *)
          val maybeStoreSExp' =
            case maybeStoreSExp of
              SOME sExp => SOME (elaborateSimpleExp (sExp, ctx, tyEnvs))
            | NONE => NONE

          fun maybeTypeOf maybeExp =
            case maybeExp of
              SOME maybeExp => SOME (CoreBOM.SimpleExp.typeOf maybeExp)
            | NONE => NONE
        in
          checkForErrorVal CoreBOM.SimpleExp.error (
            case (fieldTy, maybeTypeOf maybeStoreSExp') of
                (* make sure only mutable fields are mutated *)
              (CoreBOM.Field.Immutable (_, ty), NONE) => SOME ty
            | (CoreBOM.Field.Immutable (_, _), SOME ty) => NONE
            | (CoreBOM.Field.Mutable (_, ty), NONE) => SOME ty
            | (CoreBOM.Field.Mutable (_, ty), SOME ty') =>
                (* if a field is mutated, rhs and lhs types must match *)
                checkForErrorVal (SOME CoreBOM.BOMType.Error) (
                  CoreBOM.BOMType.equal' (ty, ty'),
                "assignment type does not match field type")
                (* and assignments always evaluate to unit *)
                (fn _ => SOME CoreBOM.BOMType.unit),
            "immutable record in assignment expression")
            (fn resultTy => CoreBOM.SimpleExp.new (
              CoreBOM.SimpleExp.RecAccess (index, recordSExp',
              maybeStoreSExp'), resultTy))
        end

    in
      case BOM.SimpleExp.node sExp of
        BOM.SimpleExp.Id longValId =>
          checkForErrorVal CoreBOM.SimpleExp.error (BOMEnv.ValEnv.lookup (
            bomEnv, CoreBOM.ValId.fromLongId longValId),
            badValId)
          (fn value => CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.Val value,
            CoreBOM.Val.typeOf value))

      | BOM.SimpleExp.PrimOp (primOp, argSExps) =>
          let
            val primArgs = map (fn sExp => elaborateSimpleExp (
              sExp, ctx, tyEnvs)) argSExps
          in
            checkForErrorVal CoreBOM.SimpleExp.error (CoreBOM.PrimOp.applyOp (
                primOp, primArgs), "invalid primop application")
            (fn primCon => CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.PrimOp
              primCon, CoreBOM.PrimOp.returnTy primCon))
          end
      | BOM.SimpleExp.HostVproc =>  CoreBOM.SimpleExp.new (
        CoreBOM.SimpleExp.HostVproc, CoreBOM.BOMType.VProc)

      | BOM.SimpleExp.Promote sExp' =>
          let
            val newExp = elaborateSimpleExp (sExp', ctx, tyEnvs)
          in
            CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.Promote newExp,
              CoreBOM.SimpleExp.typeOf newExp)
          end
      | BOM.SimpleExp.TypeCast (ty, sExp) =>
          (* make sure we only typecast Any *)
          checkForErrorVal CoreBOM.SimpleExp.error (
            let
              val (expNode, expTy) = CoreBOM.SimpleExp.dest (
                elaborateSimpleExp (sExp, ctx, tyEnvs))
            in
              if CoreBOM.BOMType.strictEqual (CoreBOM.BOMType.Any, expTy) then
                SOME expNode
              else
                NONE
            end, "only 'any' can be typecast")
          (* swap out ty for whatever type the original exp node had *)
          (fn expNode => CoreBOM.SimpleExp.new (expNode, elaborateBOMType (
            ty, tyEnvs)))
      (* | BOM.SimpleExp.Literal (* TODO: what do these become?*) *)
      | BOM.SimpleExp.AllocId (longValId, sExps) =>
          let
            (* make sure longValId is bound to a con, find its domain
            and range *)
            val (conVal, CoreBOM.BOMType.Con {dom, rng}) = lookupCon (
              CoreBOM.ValId.fromLongId longValId, tyEnvs, checkForErrorVal,
                checkForErrorVal)
          in
            elaborateTupleExp (dom, rng, sExps, conVal)
          end
      (* | BOM.SimpleExp.AllocType (tyArgs, sExps) => *)
      (*     let *)
      (*       val tyArgs' = map (fn tyArg => elaborateBOMType (tyArg, tyEnvs)) *)
      (*         tyArgs *)
      (*       (* the range is always a tuple *) *)
      (*       val rng = CoreBOM.BOMType.Tuple tyArgs' *)
      (*       (* if we only have one tyarg, then the domain is that *)
      (*          type, otherwise, we wrap it in a tuple *) *)
      (*       val dom = *)
      (*         case tyArgs' of *)
      (*           [tyArg] => tyArg *)
      (*         | tyArgs => rng *)
      (*     in *)
      (*       elaborateTupleExp (dom, rng, sExps) *)
      (*     end *)
      | BOM.SimpleExp.VpLoad (index, procExp) =>
          (* for now, we return Any *)
          CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.VpLoad (index,
            elaborateVpExp (index, procExp)), CoreBOM.BOMType.Any)

      | BOM.SimpleExp.VpStore (index, procExp, valExp) =>
          CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.VpStore (index,
            elaborateVpExp (index, procExp),
            elaborateSimpleExp (valExp, ctx, tyEnvs)),
            CoreBOM.BOMType.unit)

      | BOM.SimpleExp.VpAddr (index, procExp) =>
          CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.VpAddr (index,
           elaborateVpExp (index, procExp)),
           CoreBOM.BOMType.Addr CoreBOM.BOMType.Any)

      | BOM.SimpleExp.Select (index, recordSExp) =>
          elaborateRecordSExp (index, recordSExp, NONE)

      | BOM.SimpleExp.Assign (index, recordSExp, storeSExp) =>
          elaborateRecordSExp (index, recordSExp, SOME storeSExp)

      (* FIXME: need to split this up in to two cases *)
      (* | BOM.SimpleExp.AtIndex (index, recordSExp, maybeStoreSExp) => *)
      (*     let *)
      (*       (* make sure recordSExp evaluates to a record *) *)
      (*       val recordSExp' = elaborateSimpleExp (recordSExp, ctx, tyEnvs) *)

      (*       val fieldTys = checkForErrorVal [] *)
      (*         ((case CoreBOM.SimpleExp.typeOf recordSExp' of *)
      (*           CoreBOM.BOMType.Record fields => SOME fields *)
      (*         | _ => NONE), *)
      (*        (* TODO: phrase this better *) *)
      (*         "argument to index access expression is not a record") (fn x => x) *)

      (*       (* make sure the record is defined at the specified index *) *)
      (*       val fieldTy = checkForErrorVal CoreBOM.Field.bogus *)
      (*         (List.find (fn fieldTy => CoreBOM.Field.index fieldTy = index) *)
      (*           fieldTys, "no such index") (fn x => x) *)

      (*       (* if the rhs is a store expression, find out the type *) *)
      (*       val maybeStoreSExp' = *)
      (*         case maybeStoreSExp of *)
      (*           SOME sExp => SOME (elaborateSimpleExp (sExp, ctx, tyEnvs)) *)
      (*         | NONE => NONE *)

      (*       fun maybeTypeOf maybeExp = *)
      (*         case maybeExp of *)
      (*           SOME maybeExp => SOME (CoreBOM.SimpleExp.typeOf maybeExp) *)
      (*         | NONE => NONE *)
      (*     in *)
      (*       checkForErrorVal CoreBOM.SimpleExp.error ( *)
      (*         case (fieldTy, maybeTypeOf maybeStoreSExp') of *)
      (*             (* make sure only mutable fields are mutated *) *)
      (*           (CoreBOM.Field.Immutable (_, ty), NONE) => SOME ty *)
      (*         | (CoreBOM.Field.Immutable (_, _), SOME ty) => NONE *)
      (*         | (CoreBOM.Field.Mutable (_, ty), NONE) => SOME ty *)
      (*         | (CoreBOM.Field.Mutable (_, ty), SOME ty') => *)
      (*             (* if a field is mutated, rhs and lhs types must match *) *)
      (*             checkForErrorVal (SOME CoreBOM.BOMType.Error) ( *)
      (*               CoreBOM.BOMType.equal' (ty, ty'), *)
      (*             "assignment type does not match field type") *)
      (*             (* and assignments always evaluate to unit *) *)
      (*             (fn _ => SOME CoreBOM.BOMType.unit), *)
      (*         "immutable record in assignment expression") *)
      (*         (fn resultTy => CoreBOM.SimpleExp.new ( *)
      (*           CoreBOM.SimpleExp.RecAccess (index, recordSExp', *)
      (*           maybeStoreSExp'), resultTy)) *)
      (*     end *)

      | BOM.SimpleExp.Lit lit =>
          let
            val lit' = elaborateLiteral (lit, ctx)
          in
            CoreBOM.SimpleExp.new (CoreBOM.SimpleExp.Lit lit',
              CoreBOM.Literal.typeOf lit')
          end

      (* FIXME: intinf vector? should this be something else? *)
      | BOM.SimpleExp.MLString mlString =>
          let
            val sExp = CoreBOM.SimpleExp.MLString mlString
          (* FIXME: what type should this be? tuple? *)
          in
            CoreBOM.SimpleExp.new (sExp, CoreBOM.BOMType.Error)
          end

      | _ => raise Fail "not implemented"
    end

  and elaborateRHS (rhs, tyEnvs) =
    case BOM.RHS.node rhs of
      BOM.RHS.Composite exp =>
        let
          val exp' = elaborateExp (exp, tyEnvs)
        in
          (CoreBOM.Exp.Composite exp', CoreBOM.Exp.typeOf exp')
        end
    | BOM.RHS.Simple sExp =>
         let
             (* FIXME: this is the wrong context *)
           val sExp' = elaborateSimpleExp (sExp, BOMEnv.Context.empty, tyEnvs)
         in
           (CoreBOM.Exp.Simple sExp', [CoreBOM.SimpleExp.typeOf sExp'])
         end

  and bindVarPats (varPats, rhsTys, tyEnvs as {env, bomEnv}): (BOMEnv.t
      * CoreBOM.Val.t list) =
    (* foldl is needed for the right order *)
    ListPair.foldl (fn (varPat, rhsTy, (bomEnv', acc)) =>
      bindVarPat (varPat, rhsTy, acc, {env = env, bomEnv = bomEnv'})) (bomEnv,
      []) (varPats, rhsTys)

  (* typecheck a varpat against a type constraint. if it's not _,
  extend the value env to include it. note that foldr-ing over this
  will give you back VarPats in the reverse order *)
  and bindVarPat (varPat: BOM.VarPat.t, rhsTy, valAcc: CoreBOM.Val.t list,
      tyEnvs as {env, bomEnv}): (BOMEnv.t * CoreBOM.Val.t list) =
    let
      val check = check (error (BOM.VarPat.region, BOM.VarPat.layout,
        CoreBOM.BOMType.Error, varPat))
      fun checkTyBinding (maybeTy, rhsTy) =
        case maybeTy of
          SOME ty =>
            check (
              CoreBOM.BOMType.equal' (elaborateBOMType (ty, tyEnvs), rhsTy),
              "type constraint does not match rhs") (fn x => x)
        | NONE => rhsTy
      val (bind, maybeTy) =
        case BOM.VarPat.node varPat of
          BOM.VarPat.Wild maybeTy => ((fn _ => (bomEnv, valAcc)), maybeTy)
        | BOM.VarPat.Var (bomId, maybeTy) => (fn rhsTy =>
            let
              val newId = CoreBOM.ValId.fromBOMId bomId
              val newVal = CoreBOM.Val.new (newId, rhsTy, [])
            in
              (BOMEnv.ValEnv.extend (bomEnv, newId, newVal), newVal::valAcc)
            end, maybeTy)
      in
        bind (checkTyBinding (maybeTy, rhsTy))
      end

  and lookupVal (valId, bomEnv, checkForErrorVal) = checkForErrorVal
    CoreBOM.Val.error (BOMEnv.ValEnv.lookup (bomEnv, valId),
    badValId) (fn x => x)

  and lookupCon (valId, tyEnvs as {env, bomEnv}, checkForErrorVal,
    checkForErrorVal') =
    (* Given a ValId, make sure that it's bound to a constructor. We
    need to pass in checkForErrorVal twice since it needs to be
    instantiated at two types in the body of the function *)
    let
      val conVal = lookupVal (valId, bomEnv, checkForErrorVal)
      val dataCon: CoreBOM.BOMType.t = checkForErrorVal'
        (CoreBOM.BOMType.Con {
          dom = CoreBOM.BOMType.Error,
          rng = CoreBOM.BOMType.Error
        }) (CoreBOM.BOMType.isCon (CoreBOM.Val.typeOf conVal),
          "value identifier is not a constructor") (fn x => x)
    in
      (conVal, dataCon)
    end

  and elaborateCaseRule (caseRule, ruleExp, tyEnvs as {env, bomEnv}) =
    let
      fun errorForErrorVal errorVal = (error (BOM.CaseRule.region,
        BOM.CaseRule.layout, errorVal, caseRule))
      fun checkForErrorVal errorVal = check (errorForErrorVal errorVal)
      val ruleTy = CoreBOM.SimpleExp.typeOf ruleExp
      fun elaborateLongRule (value, varPats) =
         let
            val (conVal, conTy) = lookupCon (CoreBOM.Val.idOf value, tyEnvs,
              checkForErrorVal, checkForErrorVal)
            val (dom, rng) =
              (case conTy of
                (* A unary constructor constrains the domain and range
                to its own *)
                CoreBOM.BOMType.Con {dom, rng} => (dom, rng)
                (* FIXME: does this make sense? *)
                (* If we have a nullary constructor, the domain is unconstrained *)
              | CoreBOM.BOMType.TyCon _ => (CoreBOM.BOMType.Any, conTy)
                (* lookupCon can't return anything else *))
            (* The varpat must be in the domain of the constructor *)
            val (newBOMEnv, varPats) = bindVarPats (varPats,
              [dom], tyEnvs)
            (* And the range must be the type of the rule *)
            val _ = checkForErrorVal () (CoreBOM.BOMType.equal' (rng,
              CoreBOM.SimpleExp.typeOf ruleExp),
              "case object and rules don't agree")
          in
            (newBOMEnv, fn exp' => CoreBOM.CaseRule.LongRule (conVal, varPats,
              exp'))
          end
      fun elaboratePatRule (longId, varPats) =
        case (BOMEnv.ValEnv.lookup (bomEnv, CoreBOM.ValId.fromLongId longId),
            varPats) of
          (* either we've got a constructor *)
          (SOME value, _) => elaborateLongRule (value, varPats)
          (* or it's just varPat to be bound for the default case  *)
        | (NONE, []) =>
           let
             val newValId = CoreBOM.ValId.fromLongId longId
             val newVal = CoreBOM.Val.new (newValId, ruleTy, [])
            in
              (BOMEnv.ValEnv.extend (bomEnv, newValId, newVal),
                fn exp' => CoreBOM.CaseRule.DefaultRule (newVal, exp'))
           end
           (* or we tried to apply a non-existent constructor to
        arguments, an error *)
        | _ => errorForErrorVal (bomEnv, fn exp' =>
            CoreBOM.CaseRule.DefaultRule (CoreBOM.Val.error, exp'))
            "value identifier is not a constructor"
      fun elaborateLiteralRule literal =
        let
          val ctx = checkForErrorVal BOMEnv.Context.empty (
            (* ruleExp must be a rawTy to set the context *)
            case CoreBOM.SimpleExp.typeOf ruleExp of
              CoreBOM.BOMType.Raw rawTy => SOME rawTy
            | _ => NONE, "case object and rules don't agree")
              (fn rawTy => BOMEnv.Context.setTy (BOMEnv.Context.empty, rawTy))
          val litExp = checkForErrorVal CoreBOM.SimpleExp.error
        in
          (bomEnv, fn exp' => CoreBOM.CaseRule.LiteralRule (
            elaborateLiteral (literal, ctx), exp'))
        end
      val ((newBOMEnv, ruleCon), exp) =
        case BOM.CaseRule.node caseRule of
          BOM.CaseRule.PatRule (longId, varPats, exp) =>
            (elaboratePatRule (longId, varPats), exp)
        | BOM.CaseRule.LiteralRule (literal, exp) =>
            (elaborateLiteralRule literal, exp)
      val newExp = elaborateExp (exp, {env = env, bomEnv = newBOMEnv})
    in
      ruleCon newExp
    end

  and elaborateTyCaseRule (tyCaseRule, tyEnvs) =
    let
      val (con, exp) =
        case BOM.TyCaseRule.node tyCaseRule of
            (* FIXME: the typaram of this case statement needs to be
            bound to bomTy within exp *)
          BOM.TyCaseRule.TyRule (bomTy, exp) => (fn exp' =>
            CoreBOM.TyCaseRule.TyRule (elaborateBOMType (bomTy, tyEnvs), exp'),
            exp)
        | BOM.TyCaseRule.Default exp => (fn exp' =>
            CoreBOM.TyCaseRule.Default exp', exp)
    in
      con (elaborateExp (exp, tyEnvs))
    end

  and elaborateExp (exp: BOM.Exp.t, tyEnvs as {env, bomEnv}): CoreBOM.Exp.t =
    let
      fun errorForErrorVal errorVal = error (BOM.Exp.region,
        BOM.Exp.layout, errorVal, exp)
      fun checkForErrorVal errorVal = check (errorForErrorVal errorVal)
      fun checkRuleTys (getTy, caseRules) =
        case caseRules of
          firstRule::rules =>
            let
              (* make sure all (ty)case rules have same return type *)
              val firstTy = getTy firstRule
              val _ =
                if List.all (fn rule =>
                  CoreBOM.BOMType.equals (firstTy, getTy rule)) caseRules
              then ()
              else errorForErrorVal () "types of rules don't agree"
            in
              firstTy
            end
        | _ => []
      (* Default context *)
      val ctx = BOMEnv.Context.empty
    in
      case BOM.Exp.node exp of
        BOM.Exp.Return sExps =>
          let
            val exps = map (fn sExp => elaborateSimpleExp (sExp, ctx,
              tyEnvs)) sExps
          in
            CoreBOM.Exp.new (CoreBOM.Exp.Return exps,
              map CoreBOM.SimpleExp.typeOf exps)
          end
      | BOM.Exp.If (sExp, left, right) =>
          let
            val check = checkForErrorVal [CoreBOM.BOMType.Error]
            fun doElaborate exp = elaborateExp (exp, tyEnvs)
            (* TODO: make sure this is a boolean primop *)
            fun checkArgument sExp' =
              case BOM.SimpleExp.node sExp' of
                BOM.SimpleExp.PrimOp (primOp, args) =>
                  SOME (primOp, map (fn sExp => elaborateSimpleExp (sExp, ctx,
                    tyEnvs)) args)
              | _ => NONE

            val [left', right'] = map (fn exp => elaborateExp (
              exp, tyEnvs)) [left, right]
            val [leftTy, rightTy] = map CoreBOM.Exp.typeOf [left', right']
          in
            (* check that we've gotten a primitive conditional *)
            checkForErrorVal CoreBOM.Exp.error (checkArgument sExp,
              "test expression in if is not a primitive conditional")
              (* if we have, try to apply it to the arguments *)
              (fn (primOp, sExps) => checkForErrorVal CoreBOM.Exp.error (
                CoreBOM.PrimOp.applyCond (primOp, sExps),
                "invalid primitive conditional")
                (* if we have a valid test expression, check the branch types agree *)
                (fn primCond => checkForErrorVal CoreBOM.Exp.error (
                  CoreBOM.BOMType.equals' (leftTy, rightTy),
                  "types of if branches do not agree")
                  (* if they do, return the appropriate expression *)
                  (fn resultTy => CoreBOM.Exp.new (CoreBOM.Exp.If (primCond,
                    left', right'), resultTy))))
          end
      | BOM.Exp.Case (exp, caseRules) =>
          let
            val caseExp = elaborateSimpleExp (exp, ctx, tyEnvs)
            val caseRules' = map (fn caseRule => elaborateCaseRule (caseRule,
              caseExp, tyEnvs)) caseRules
            (* fun tyOfPair (left, right) = (CoreBOM.CaseRule.returnTy left, *)
            (*   CoreBOM.CaseRule.returnTy right) *)
            val rulesTy = checkRuleTys (CoreBOM.CaseRule.returnTy, caseRules')
          in
            CoreBOM.Exp.new (CoreBOM.Exp.Case (caseExp, caseRules'), rulesTy)
          end
      | BOM.Exp.Typecase (tyParam, tyCaseRules) =>
          checkForErrorVal CoreBOM.Exp.error (BOMEnv.TyParamEnv.lookup (bomEnv,
            tyParam), "unbound typaram")
          (fn tyParam' =>
            let
              val tyCaseRules' = map (fn tyCaseRule => elaborateTyCaseRule (
                tyCaseRule, tyEnvs)) tyCaseRules
            in
              CoreBOM.Exp.new (CoreBOM.Exp.Typecase (tyParam', tyCaseRules'),
                checkRuleTys (CoreBOM.TyCaseRule.returnTy, tyCaseRules'))
            end)
      | BOM.Exp.Let (varPats, rhs, exp) =>
          let
            val (rhsExp, rhsTys) = elaborateRHS (rhs, tyEnvs)
            val (newBOMEnv, patVals) =
              checkForErrorVal (bomEnv, []) (
                if length rhsTys = length varPats
                  then SOME tyEnvs
                else NONE,
              "left and right side of let binding are of different lengths")
              (fn tyEnvs => bindVarPats (varPats, rhsTys, tyEnvs))
            val resultExp = elaborateExp (exp, {env = env, bomEnv = newBOMEnv})
          in
            CoreBOM.Exp.new (CoreBOM.Exp.Let (patVals,
              rhsExp, resultExp), CoreBOM.Exp.typeOf resultExp)
          end
      | BOM.Exp.Do (sExp, exp) =>
          let
            val returnExp = elaborateExp (exp, tyEnvs)
          in
            CoreBOM.Exp.new (CoreBOM.Exp.Do (elaborateSimpleExp (sExp, ctx,
              tyEnvs), returnExp), CoreBOM.Exp.typeOf returnExp)
          end
      | BOM.Exp.Throw (bomId, sExps) =>
          (* TODO: this will give an unhelpful message if bomId isn't a cont *)
          (* make sure the value identifier is bound *)
          checkForErrorVal CoreBOM.Exp.error (BOMEnv.ValEnv.lookup (bomEnv,
            CoreBOM.ValId.fromBOMId bomId), badValId)
            (fn contVal =>
              let
                val arguments = map (fn sExp => elaborateSimpleExp (sExp, ctx,
                  tyEnvs)) sExps
              in
                (* make sure the value id is bound to a continuation
                of the same type as the arguments *)
                checkForErrorVal CoreBOM.Exp.error
                  (CoreBOM.BOMType.equal' (CoreBOM.BOMType.Cont (
                    map CoreBOM.SimpleExp.typeOf arguments),
                    CoreBOM.Val.typeOf contVal),
                  "throw arguments do not match continuation type")
                  (fn returnTy => CoreBOM.Exp.new (CoreBOM.Exp.Throw (
                    contVal, arguments), [returnTy]))
              end)
      | BOM.Exp.FunExp (funDefs, exp) =>
          let
            val (envWithFns, funDefs') = elaborateFunDefs (funDefs, tyEnvs)
            val bodyExp = elaborateExp (exp, envWithFns)
          in
            CoreBOM.Exp.new (CoreBOM.Exp.FunExp (funDefs', bodyExp),
              CoreBOM.Exp.typeOf bodyExp)
          end
      | BOM.Exp.Apply (longId, domExps, contExps) =>
          let
            (* FIXME: deal with typarams *)
            (* make sure longId is bound *)
            val funVal = lookupVal (CoreBOM.ValId.fromLongId longId,
              bomEnv, checkForErrorVal)
            (* make sure it's bound to a function type *)
            val CoreBOM.BOMType.Fun {dom, cont, rng} = checkForErrorVal
              (CoreBOM.BOMType.Fun {dom = [CoreBOM.BOMType.Error],
               cont = [CoreBOM.BOMType.Error],
               rng = [CoreBOM.BOMType.Error]}) (CoreBOM.BOMType.isFun (
                 CoreBOM.Val.typeOf funVal),
                 "value identifier is not a function") (fn x => x)
            val emptyCtx = BOMEnv.Context.empty
            fun doSElaborate (sExp, ty) =
              let
                val sExp' =
                  case ty of
                    CoreBOM.BOMType.Raw raw =>
                      elaborateSimpleExp (sExp, BOMEnv.Context.setTy (emptyCtx,
                        raw), tyEnvs)
                    | _ => elaborateSimpleExp (sExp, emptyCtx, tyEnvs)
              in
                checkForErrorVal CoreBOM.SimpleExp.error (
                  CoreBOM.BOMType.equal' (ty, CoreBOM.SimpleExp.typeOf sExp'),
                  "operator and operand don't agree") (fn _ => sExp')
              end
            fun elabWithTyConstraints (sExps, tys) =
              ListPair.mapEq doSElaborate (sExps, tys)
                handle ListPair.UnequalLengths => errorForErrorVal []
                  "operator and operand don't agree"
            val [domExps', contExps'] = map elabWithTyConstraints [(domExps,
              dom), (contExps, cont)]
         in
           CoreBOM.Exp.new (CoreBOM.Exp.Apply (funVal, domExps', contExps'),
             rng)
         end
      | BOM.Exp.ContExp (bomId, args, contExp, bodyExp) =>
          let
            val contVal = checkForErrorVal CoreBOM.Val.error (
              BOMEnv.ValEnv.lookup (bomEnv, CoreBOM.ValId.fromBOMId bomId),
              badValId) (fn x => x)
            val CoreBOM.BOMType.Cont contTys = checkForErrorVal
              (CoreBOM.BOMType.Cont []) (CoreBOM.BOMType.isCont
                (CoreBOM.Val.typeOf contVal),
                "value identifier is not a continuation") (fn x => x)
            val (newEnv, contArgs) = bindVarPats (args, contTys, tyEnvs)
            (* FIXME: contExp' needs to have continuation type? *)
            val contExp' = elaborateExp (contExp, {env = env, bomEnv = newEnv})
            val bodyExp' = elaborateExp (bodyExp, {env = env, bomEnv = newEnv})
          in
            CoreBOM.Exp.new (CoreBOM.Exp.ContExp (contVal, contArgs, contExp',
              bodyExp'), CoreBOM.Exp.typeOf bodyExp')
          end
    end

  fun dataTypeDefToTyIdAndParams dtDef =
    let
      val (tyId, tyParams) =
        ((fn BOM.DataTypeDef.ConsDefs (astId, maybeTyParams, _) =>
          (CoreBOM.TyId.fromBOMId astId, maybeTyParams))
          (BOM.DataTypeDef.node dtDef))
    in
      (tyId, tyParams)
    end


  fun extendEnvForDataTypeDef (dtDef: BOM.DataTypeDef.t,
      tyEnvs as {env:Env.t, bomEnv: BOMEnv.t}) =
    let
      val (tyId, tyParams) = dataTypeDefToTyIdAndParams dtDef
    in
      {
        env = env,
        bomEnv = BOMEnv.TyEnv.extend (bomEnv, tyId, BOMEnv.TypeDefn.newCon (
          CoreBOM.TyCon.new (tyId, map CoreBOM.TyParam.fromAst tyParams)))
      }
    end

  fun elaborateDataConsDef (dtCon: BOM.DataConsDef.t,
      datatypeTy: CoreBOM.BOMType.t,
      tyEnvs as {env:Env.t, bomEnv: BOMEnv.t}):
      (CoreBOM.DataConsDef.t * BOMEnv.t) =
    let
      val BOM.DataConsDef.ConsDef (astId, maybeTy) =
        BOM.DataConsDef.node dtCon
      val params = CoreBOM.BOMType.uniqueTyParams datatypeTy
      val valId = CoreBOM.ValId.fromBOMId astId
      val (maybeArgTy: CoreBOM.BOMType.t option, valTy: CoreBOM.BOMType.t) =
        case (maybeTy: BOM.BOMType.t option) of
          SOME (argTy: BOM.BOMType.t) =>
            let
              val argTy = elaborateBOMType (argTy, tyEnvs)
            in
              (SOME argTy, CoreBOM.BOMType.Con {dom = argTy, rng = datatypeTy})
            end
        | NONE => (NONE, datatypeTy)
    in
      (CoreBOM.DataConsDef.ConsDef (
        CoreBOM.BOMId.fromAst astId, maybeArgTy),
      BOMEnv.ValEnv.extend (bomEnv, valId, CoreBOM.Val.new (valId, valTy,
        params)))
    end


  fun elaborateDataConsDefs (dtCons: BOM.DataConsDef.t list,
      datatypeTy: CoreBOM.BOMType.t, tyEnvs as {env:Env.t, bomEnv: BOMEnv.t}) =
    foldr (fn (newAstCon, (oldEnv, oldCons)) =>
      let
        val (newCon, newEnv) = elaborateDataConsDef (
          newAstCon, datatypeTy, {env=env, bomEnv=oldEnv})
      in
        (newEnv, newCon::oldCons)
      end) (bomEnv, []) dtCons


  fun elaborateDataTypeDef (dtDef: BOM.DataTypeDef.t,
      tyEnvs as {env:Env.t, bomEnv: BOMEnv.t}) =
    let
      val error = error (BOM.DataTypeDef.region, BOM.DataTypeDef.layout,
        tyEnvs, dtDef)
      val check = check error

      val (tyId, tyParams) = dataTypeDefToTyIdAndParams dtDef
      val SOME (tyConOfDatatype) = BOMEnv.TyEnv.lookupCon (bomEnv, tyId)
      val envWithTyParams = extendEnvForTyParams (bomEnv, tyParams)
      val newEnvs =
        case BOM.DataTypeDef.node dtDef of
          BOM.DataTypeDef.ConsDefs (_, _, consDefs) =>
            let
              val (newEnv, dtCons) = elaborateDataConsDefs (consDefs,
                CoreBOM.TyCon.toBOMTy tyConOfDatatype,
                {env = env, bomEnv = envWithTyParams})
              val CoreBOM.TyCon.TyC {definition, params, ...} =
                tyConOfDatatype
            in
              definition := dtCons
              ; {
                env = env,
                bomEnv = newEnv
              }
            end
    in
      newEnvs
    end

  (* FIXME: these should be returning bomdecs *)
  fun elaborateBOMDec (dec: BOM.Definition.t, tyEnvs as {env, bomEnv}) =
    case BOM.Definition.node dec of
       BOM.Definition.Extern (cReturnTy, bomId, cArgTys, maybeAttrs) =>
         let
           val cReturnTy' = CoreBOM.CReturnTy.fromAst cReturnTy
           val cArgTys' = map CoreBOM.CArgTy.fromAst cArgTys
           val attrs' = CoreBOM.Attr.flattenFromAst maybeAttrs
           (* TODO: what type should this value have? does it go in VE? *)
           val valId = CoreBOM.Val.error
           val dec = CoreBOM.Definition.Extern (cReturnTy', valId, cArgTys', attrs')
         in
           (CoreML.Dec.BOMDecs [], bomEnv)
         end
    |  BOM.Definition.Datatype dtdefs =>
         let
           val envWithTys = foldl extendEnvForDataTypeDef tyEnvs dtdefs
           val envWithDefs = foldl elaborateDataTypeDef envWithTys dtdefs
         in
           (CoreML.Dec.BOMDecs [], #bomEnv envWithDefs)
         end
    (* | BOM.Definition.DatatypeAlias (bomId, longTyId) => *)
    (*     let *)
    (*       val error = error (BOM.LongTyId.region, BOM.LongTyId.layout, *)
    (*         BOMEnv.TypeDefn.error, longTyId) *)
    (*       val check = check error *)
    (*       val tyId = CoreBOM.TyId.fromBOMId bomId *)

    (*       val tyConDefn = *)
    (*         (* TODO: can't get this to compile if the last line extends env *) *)
    (*         check *)
    (*           (BOMEnv.TyEnv.lookup (bomEnv, *)
    (*             CoreBOM.TyId.fromLongTyId longTyId): BOMEnv.TypeDefn.t option, *)
    (*               "undefined type") *)
    (*             (fn tyDefn: BOMEnv.TypeDefn.t => check *)
    (*               ((BOMEnv.TypeDefn.isCon tyDefn): BOMEnv.TypeDefn.t option, *)
    (*                 "not a datatype") *)
    (*               (fn x => x)) *)
    (*     in *)
    (*       (CoreML.Dec.BOMDecs [], BOMEnv.TyEnv.extend (bomEnv, tyId, tyConDefn)) *)
    (*     end *)

    | BOM.Definition.TypeDefn (bomId, maybeTyParams, bomTy) =>
        let
          val error = error (BOM.BOMType.region, BOM.BOMType.layout,
            BOMEnv.TypeDefn.error, bomTy)
          fun checkArityMatches (typeDefn, ty) =
            let
              val defnArity = BOMEnv.TypeDefn.arity typeDefn
              val tyArity = CoreBOM.BOMType.arity ty
            in
              if defnArity = tyArity then
                typeDefn
              else
                error "arity mismatch"
            end

          val envWithTyParams: BOMEnv.t = extendEnvForTyParams (
            bomEnv, maybeTyParams)
          val newTy = elaborateBOMType (
            bomTy, {env = env, bomEnv = envWithTyParams})
          (* alias is the only kind we can get from this *)
          val newTyAlias = checkArityMatches (
            BOMEnv.TypeDefn.newAlias ({
              params = BOMEnv.TyParamEnv.getParams envWithTyParams,
              ty = newTy
             }),
             newTy)

          val newId = CoreBOM.TyId.fromBOMId bomId

          val newEnv = BOMEnv.TyEnv.extend (bomEnv, newId, newTyAlias)
        in
          (CoreML.Dec.BOMDecs [], newEnv)
        end
    | BOM.Definition.Fun funDefs =>
        let
          val (envWithFns, funDefs) = elaborateFunDefs (funDefs, tyEnvs)
        in
          (CoreML.Dec.BOMDecs [], #bomEnv envWithFns)
        end
    (* | BOM.Definition.InstanceType instanceTy => *)
    (*     let *)
    (*       val ty = elaborateBOMType (instanceTyToTy instanceTy, tyEnvs) *)
    (*     (* TODO: deal with extending the environment *) *)
    (*     in *)
    (*       (CoreML.Dec.BOMDecs [], bomEnv) *)
    (*     end *)
    | _ => raise Fail "not implemented"
    (* TODO: the other cases *)

    (* (CoreML.Dec.BOMDec, bomEnv) *)
end
