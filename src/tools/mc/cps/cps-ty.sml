(* cps-ty.sml
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *)

structure CPSTy =
  struct

    datatype raw_ty = datatype RawTypes.raw_ty

    datatype ty
      = T_Any				(* unknown type; uniform representation *)
      | T_Enum of Word.word		(* unsigned tagged integer; word is max value <= 2^31-1 *)
      | T_Raw of raw_ty			(* raw machine type *)
      | T_Wrap of raw_ty		(* boxed raw value *)
      | T_Tuple of bool * ty list	(* heap-allocated tuple; the boolean is true for *)
					(* mutable tuples *)
      | T_Addr of ty			(* address of a tuple's field *)
      | T_Fun of (ty list * ty list)	(* function/continuation type; the second list of types *)
					(* are the types of the return continuations *)
      | T_CFun of CFunctions.c_proto	(* C functions *)
      | T_VProc				(* address of VProc runtime structure *)

    val unitTy = T_Enum(0w0)
    val boolTy = T_Enum(0w1)	(* false = 0, true = 1 *)

    fun toString ty = let
	  fun tys2l ([], l) = l
	    | tys2l ([ty], l) = toString ty :: l
	    | tys2l (ty::tys, l) =
		toString ty ::
		  (List.foldr (fn (ty, l) => "," :: toString ty :: l) l tys)
	  in
	    case ty
	     of T_Any => "any"
	      | T_Enum w => concat["enum(", Word.fmt StringCvt.DEC w, ")"]
	      | T_Raw ty => RawTypes.toString ty
	      | T_Wrap ty => concat["wrap(", RawTypes.toString ty, ")"]
	      | T_Tuple(false, tys) => concat("(" :: tys2l(tys, [")"]))
	      | T_Tuple(true, tys) => concat("!(" :: tys2l(tys, [")"]))
	      | T_Addr ty => concat["addr(", toString ty, ")"]
	      | T_Fun(tys, []) => concat("cont(" :: tys2l(tys, [")"]))
	      | T_Fun(tys1, tys2) => concat("fun(" :: tys2l(tys1, ";" :: tys2l(tys2, [")"])))
	      | T_CFun cp => CFunctions.protoToString cp
	      | T_VProc => "vproc"
	    (* end case *)
	  end

  (* a continuation type has no return or exception continuations *)
    fun contTy paramTys = T_Fun(paramTys, [])

  (* extract the return continuation type from a function type *)
    fun returnTy (T_Fun(_, ty::_)) = ty
      | returnTy ty = raise Fail("expected function type, but found " ^ toString ty)

  end
