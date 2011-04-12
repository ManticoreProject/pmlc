(* translate-range.sml
 *
 * COPYRIGHT (c) 2009 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 * 
 * This module rewrites ranges in terms of calls to Rope.rangeP.
 *)

structure TranslateRange : sig

    val tr : AST.exp * AST.exp * AST.exp option * AST.ty -> AST.exp

  end = struct

    structure A = AST
    structure B = Basis
    structure T = Types

    structure AU = ASTUtil

    local
      fun get v = BasisEnv.getVarFromBasis ["PArray", v]
      val m1 = Memo.new (fn _ => get "rangeP")
    in
      fun rangeP () = Memo.get m1
    end

  (* tr : A.exp * A.exp * A.exp option * A.ty -> A.exp *)
  (* FIXME right now this only works at type int; it's designed otherwise *)
    fun tr (fromExp, toExp, optStepExp, ty) = let
      val stepExp = (case optStepExp
        of SOME e => e
	 | NONE => AU.mkInt 1
        (* end case *))
      in
        AU.mkApplyExp (A.VarExp (rangeP (), []), [fromExp, toExp, stepExp])
      end

  end
