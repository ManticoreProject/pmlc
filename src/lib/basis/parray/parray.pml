(* parray.pml
 *
 * COPYRIGHT (c) 2009 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Parallel array utilities.
 *)

structure PArray = struct

    _primcode (
    	define inline @to-rope (x : parray / _ : exh) : Rope.rope =
    	    return ((Rope.rope)x)
    	  ;
    	define inline @from-rope (x : Rope.rope / _ : exh) : parray =
    	    return ((parray)x)
    	  ;
      )

    type 'a parray = 'a parray

(*   (\* FIXME too tightly coupled with Rope *\) *)

(* FIXME had to expose toRope and fromRope to enable special treatment of them in the flatt. trns. *)
    (* local *)
      val toRope : 'a parray -> 'a Rope.rope = _prim(@to-rope)
      val fromRope : 'a Rope.rope -> 'a parray = _prim(@from-rope)
    (* in *)

    fun sub (pa, i) = Rope.sub(toRope pa, i)
    fun length pa = Rope.length(toRope pa)
    fun tab (n, f) = fromRope(Rope.tabP(n, f))
    fun tabFromToStep (a, b, step, f) = fromRope(Rope.tabFromToStepP(a, b, step, f))
    fun map f pa = fromRope(Rope.mapP (f, toRope pa))
    fun reduce assocOp init pa = Rope.reduceP (assocOp, init, toRope pa)
    fun range (from, to_, step) = fromRope(Rope.rangeP (from, to_, step))
    fun app f pa = Rope.app (f, toRope pa)

(*     fun filter (pred, pa) = fromRope(Rope.filterP (pred, toRope pa)) *)
(*     fun rev pa = fromRope(Rope.revP(toRope pa)) *)
(*     fun fromList l = fromRope(Rope.fromList l) *)
(*     fun concat (pa1, pa2) = fromRope(Rope.concat(toRope pa1, toRope pa2)) *)
(*     fun tabulateWithPred (n, f) = fromRope(Rope.tabP(n, f)) *)
(*     fun forP (n, f) = Rope.forP(n,f) *)

(*   (\* repP : int * 'a -> 'a parray *\) *)
(*   (\* called "dist" in NESL and Keller *\) *)
(*   (\* called "replicateP" in DPH impl *\) *)
(*     fun repP (n, x) = fromRope(Rope.tabP (n, fn _ => x)) *)

    (* end (\* local *\) *)

(* Unfortunately one cannot write polymorphic parray functions at present. *)
(* Therefore I am providing some common useful monomorphic functions that really *)
(* should be instances of a single polymorphic one. *)

  fun tos_int parr = let
    fun tos i = Int.toString(parr!i)
    fun lp (i, acc) =
      if (i<0) then
        String.concat ("[|"::acc)
      else
        lp (i-1, tos(i)::","::acc)
    val n = length parr
    in
      if (n<0) then (raise Fail "bug")
      else if (n=0) then "[||]"
      else let
        val init = [tos(n-1),"|]"]
        in
          lp (n-2, init)
        end
    end

  fun tos_float parr = let
    fun tos i = Float.toString(parr!i)
    fun lp (i, acc) =
      if (i<0) then
        String.concat ("[|"::acc)
      else
        lp (i-1, tos(i)::","::acc)
    val n = length parr
    in
      if (n<0) then (raise Fail "bug")
      else if (n=0) then "[||]"
      else let
        val init = [tos(n-1),"|]"]
        in
          lp (n-2, init)
        end
    end  

  fun tos_intPair parr = let
    val itos = Int.toString
    fun tos i = let
      val (m,n) = parr!i 
      in
        "(" ^ itos m ^ "," ^ itos n ^ ")"
      end
    fun lp (i, acc) =
      if (i<0) then
        String.concat ("[|"::acc)
      else
        lp (i-1, tos(i)::","::acc)
    val n = length parr
    in
      if (n<0) then (raise Fail "bug")
      else if (n=0) then "[||]"
      else let
        val init = [tos(n-1),"|]"]
        in
          lp (n-2, init)
        end
    end

  fun tos_intParr parr = let
    fun tos i = tos_int (parr!i)
    fun lp (i, acc) =
      if (i<0) then
        String.concat ("[|"::acc)
      else
        lp (i-1, tos(i)::","::acc)
    val n = length parr
    in
      if (n<0) then (raise Fail "bug")
      else if (n=0) then "[||]"
      else let
        val init = [tos(n-1),"|]"]
        in
          lp (n-2, init)
        end
    end
 
end

(* (\* FIXME: the following definitions should be in a separate *)
(*  * file (a la sequential/pervasives.pml) *)
(*  *\) *)
(* (\* below is the subset of the parallel array module that should bound at the top level. *\) *)
(* val reduceP = PArray.reduce *)
(* val filterP = PArray.filter *)
(* val subP = PArray.sub *)
(* val revP = PArray.rev *)
(* val lengthP = PArray.length *)
(* val mapP = PArray.map *)
(* val fromListP = PArray.fromList *)
(* val concatP = PArray.concat *)
(* val tabP = PArray.tabulateWithPred *)
(* val forP = PArray.forP *)

