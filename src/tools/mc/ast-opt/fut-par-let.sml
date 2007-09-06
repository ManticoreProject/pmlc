(* fut-par-let.sml
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 * 
 * This module rewrites parallel bindings in terms of futures, touches and cancels.
 *
 * Note this rewriting is type preserving.
 *)

structure FutParLet (* : sig

    val futurize : A.module -> A.module
    val test : int -> unit

  end *) = 

  struct

    structure A = AST
    structure T = Types
    structure F = Futures

    (* fail : string -> 'a *)
    fun fail msg = raise Fail msg

    (* todo : string -> 'a *)
    fun todo thing = fail ("todo: " ^ thing)

    infixr **
    (* (**) : ('a -> 'b) * ('c -> 'd) -> ('a * 'c) -> ('b * 'd) *)
    fun f ** g = (fn (a, c) => (f a, g c))

    (* id : 'a -> 'a *)
    val id = fn x => x

    structure OrdVar = 
      struct
        type ord_key = Var.var
	val compare = Var.compare
      end

    structure VSet = RedBlackSetFn (OrdVar)

    (* grandUnion : VSet.set list -> VSet.set *)
    (* Computes the union of all the sets in the given list. *)
    val grandUnion = List.foldl VSet.union VSet.empty

    (* minus : VSet.set * Var.var -> VSet.set *)
    (* Unlike VSet.delete, this doesn't throw an exception if the elt is absent. *)
    fun minus (s, x) = VSet.difference (s, VSet.singleton x)

    (* varsInPat : A.pat -> VSet.set *)
    val varsInPat =
	let (* vs : A.pat -> A.var list *)
	    fun vs (A.ConPat (_, _, p)) = vs p
	      | vs (A.TuplePat ps) = List.concat (map vs ps)
	      | vs (A.VarPat x) = [x]
	      | vs (A.WildPat t) = []
	      | vs (A.ConstPat _) = []
	in
	    VSet.fromList o vs
	end

    (* futureMap : VSet.set -> VarSubst.subst *)
    fun futureMap vs = todo "futureMap"

    (* exp : A.exp * VSet.set -> A.exp * VSet.set *)
    (* Consumes an expression and the set of pval-bound variables *)
    (*   live in the expression. *)
    (* Produces a rewritten-with-futures-etc. expression and the set *)
    (*   of pval-bound variables live therein. *)
    fun exp (A.LetExp (b, e), pLive) = letExp (b, e, pLive)
      | exp (A.IfExp (e1, e2, e3, t), pLive) = ifExp (e1, e2, e3, t, pLive)
      | exp (A.CaseExp (e, pes, t), pLive) = todo "CaseExp"
      | exp (A.FunExp (x, e, t), pLive) =
	  let val (e', pLive') = exp (e, pLive)
	  in
	      (A.FunExp (x, e', t), pLive')
	  end
      | exp (A.ApplyExp (e1, e2, t), pLive) = 
	  let val (e1', live1) = exp (e1, pLive)
	      val (e2', live2) = exp (e2, pLive)
	      val pLive' = VSet.union (live1, live2)
	  in
	      (A.ApplyExp (e1', e2', t), pLive')
	  end
      | exp (A.TupleExp es, pLive) =
	  let val ess = map (fn e => exp (e, pLive)) es
	      val (es', ss) = ListPair.unzip ess
	  in
	      (A.TupleExp es', grandUnion ss)
	  end
      | exp (A.RangeExp (e1, e2, oe3, t), pLive) = todo "RangeExp"
      | exp (A.PTupleExp es, pLive) = todo "PTupleExp"
      | exp (A.PArrayExp (es, t), pLive) = todo "PArrayExp"
      | exp (A.PCompExp (e, pes, oe), pLive) = todo "PCompExp"
      | exp (A.PChoiceExp (es, t), pLive) = todo "PChoiceExp"
      | exp (A.SpawnExp e, pLive) =
	  let val (e', pLive') = exp (e, pLive)
	  in
	      (A.SpawnExp e', pLive')
	  end
      | exp (k as A.ConstExp _, pLive) = (k, pLive)
      | exp (v as A.VarExp (x, ts), pLive) = 
	  if VSet.member (pLive, x) 
	  then (F.mkTouch v, VSet.singleton x)
	  else (v, VSet.empty)
      | exp (A.SeqExp (e1, e2), pLive) = 
	  let val (e1', live1) = exp (e1, pLive)
	      val (e2', live2) = exp (e2, pLive)
	  in
	      (A.SeqExp (e1', e2'), VSet.union (live1, live2))
	  end
      | exp (ov as A.OverloadExp _, pLive) = (ov, pLive)

    (* letExp : A.binding * A.exp * VSet.set -> A.exp -> VSet.set *)
    and letExp (A.ValBind (p, e1), e2, pLive) = 
	  let val pvs = varsInPat p
	      val (e1', plive1) = exp (e1, pLive)
	      val (e2', plive2) = exp (e2, pLive)
	      val pliveOut = VSet.union (plive1, VSet.difference (plive2, 
								  pvs))
	      val b' = A.ValBind (p, e1')
	  in
	      (A.LetExp (b', e2'), pliveOut)
	  end
      | letExp (A.PValBind (p, e1), e2, pLive) = 
	  (case p
	     of A.VarPat x =>
                   (* We'll handle a relatively easy case for starters. *)
		let val (e1', live1) = exp (e1, pLive)
		    val e1f = F.mkFuture e1'
		    val xf  = Var.new ("xf", TypeOf.exp e1f)
		    val (e2', live2) = exp (e2, pLive)
		    val e2t = 
			let val s = VarSubst.singleton (x, xf)
			in
			    VarSubst.touchExp s e2'
			end
		    val pliveOut = 
			let val s = grandUnion [VSet.singleton xf, live1, live2]
			in
			    minus (s, x)
			end
		in
		    (A.LetExp (A.ValBind (A.VarPat xf, e1f), e2t), pliveOut)
		end
	      | _ => todo "letExp.PValBind")
(*
The more general idea is to transform

             let pval p = e in e' end

          into

             let val f = future (fn () => case e
                                            of p => vs p
            (* where vs p produces the list or tuple of vars in p *)
                                             | _ => raise Bind)
             in
                 [x -> nth (touch f, n)] e' (* if f is a list *)
                 (* or alternatively *)
                 [x -> #n (touch f)] e'     (* if f is a tuple *)
                 (* where n is the position of x in (vs p) *)
             end

             We don't yet (8/23) have # or nth in our language.
             (We don't have exceptions yet either.)

             -ams
*)
      | letExp (A.FunBind lams, e, pLive) = 
	  let val lams' = map (lambda pLive) lams
	      val (e', live1) = exp (e, pLive)			
	  in
	      (A.LetExp (A.FunBind lams', e'), live1)
	  end

    (* lambda : VSet.set -> A.lambda -> A.lambda *)
    and lambda pLive (A.FB (f, x, e)) = A.FB (f, x, #1 (exp (e, pLive)))

    (* ifExp : A.exp * A.exp * A.exp * T.ty * VSet.set -> A.exp * VSet.set *)
    and ifExp (e1, e2, e3, t, pLive) =
	let val (e1', pLiveC) = exp (e1, pLive)
	    val (e2', pLiveT) = exp (e2, pLive)
	    val (e3', pLiveF) = exp (e3, pLive)
	    (* compute the variables that need to be cancelled *)
	    val canT = VSet.difference (VSet.intersection (pLive, pLiveF), pLiveT)
	    val canF = VSet.difference (VSet.intersection (pLive, pLiveT), pLiveF)
	    (* cancel : A.var * A.exp -> A.exp *)
	    fun cancel (x, e) = A.SeqExp (F.mkCancel (A.VarExp (x, [])), e)
                                (*                                 ^^               *)
                                (* ??? Is it OK not to instantiate the 'a future? ??? *)
	    val e2' = VSet.foldl cancel e2' canT
	    val e3' = VSet.foldl cancel e3' canF
	    val pLiveOut = grandUnion [pLiveC, pLiveT, pLiveF]
	in
	    (A.IfExp (e1', e2', e3', t), pLiveOut)
	end
	    
    (* futurize : A.module -> A.module *)
    fun futurize m = #1 (exp (m, VSet.empty))

    (**** tests ****)

    local

	structure U = TestUtils

	val t0 = U.int 0

	(* t1 = let pval x = fact 10 in x end *)
	val t1 =
	    let val x = Var.new ("x", Basis.intTy)
		val b = A.VarExp (x, [])
	    in
		U.plet (x, U.fact 10, b)
	    end

	(* t2 = let pval x = fact 10 in if true then x else 1 *)
	val t2 = 
	    let val x = Var.new ("x", Basis.intTy)
		val xexp = A.VarExp (x, [])
		val b = U.ifexp (U.trueExp, xexp, U.int 1)
	    in
		U.plet (x, U.fact 10, b)
	    end

	(* testPVal : A.exp -> unit *)
	fun testPVal e = (PrintAST.print e;
			  PrintAST.printComment "-->";
			  PrintAST.print (futurize e))

    in
        (* test : int -> unit *)
        val test = U.mkTest testPVal [t0,t1,t2]
    end

  end
