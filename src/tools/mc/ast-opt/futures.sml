(* futures.sml
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * This file includes definitions of future, touch, and cancel, for use
 * in transformations of intermediate languages.
 *)

structure Futures (* : sig

    val futureTyc : Types.tycon
    val futureTy  : Types.ty -> Types.ty

    val mkFuture  : AST.exp -> AST.exp 
    val mkTouch   : AST.exp -> AST.exp
    val mkCancel  : AST.exp -> AST.exp

    val mkFuture1 : AST.exp -> AST.exp
    val mkTouch1  : AST.exp -> AST.exp
    val mkCancel1 : AST.exp -> AST.exp

  end *) =

  struct
  
    structure A = AST
    structure T = Types
    
    (* fail : string -> 'a *)
    fun fail msg = raise Fail msg

    (* todo : string -> 'a *)
    fun todo thing = fail ("todo: " ^ thing)
			 
    (* futureTyc : T.tycon *)
    val futureTyc = TyCon.newAbsTyc (Atom.atom "future", 1, false)

    (* futureTy : T.ty -> T.ty *)
    fun futureTy t = T.ConTy ([t], futureTyc)
		    
    (* forall : (T.ty -> T.ty) -> T.ty_scheme *)
    fun forall mkTy =
	let val tv = TyVar.new (Atom.atom "'a")
	in
	    T.TyScheme ([tv], mkTy (A.VarTy tv))
	end

    (* polyVar : Atom.atom * (T.ty -> T.ty) -> Var.var *)
    fun polyVar (name, mkTy) = Var.newPoly (Atom.toString name, forall mkTy)

    val --> = T.FunTy
    infixr 8 -->

    (* predefined functions *)
    val future = polyVar (Atom.atom "future",
 		          fn tv => (Basis.unitTy --> tv) --> futureTy tv)

    val touch = polyVar (Atom.atom "touch",
		         fn tv => futureTy tv --> tv)

    val cancel = polyVar (Atom.atom "cancel",
			  fn tv => futureTy tv --> Basis.unitTy)

    val future1 = polyVar (Atom.atom "future1",
			   fn tv => (Basis.unitTy --> tv) --> futureTy tv)

    val touch1 = polyVar (Atom.atom "touch1",
			  fn tv => futureTy tv --> tv)

    val cancel1 = polyVar (Atom.atom "cancel1",
			   fn tv => futureTy tv --> Basis.unitTy)

    (* mkThunk : A.exp -> A.exp *)
    (* Consumes e; produces (fn u => e) (for fresh u : unit). *)
    fun mkThunk e =
	let val te = TypeOf.exp e
	    val uTy = Basis.unitTy
	in
	    A.FunExp (Var.new ("u", uTy), e, T.FunTy (uTy, te))
	end

    (* mkFut : var -> A.exp -> A.exp *)
    (* Consumes e; produces future (fn u => e). *)
    fun mkFut futvar e = 
	let val te = TypeOf.exp e
	in
	    A.ApplyExp (A.VarExp (futvar, [te]), mkThunk e, futureTy te)
	end

    (* mkFuture : A.exp -> A.exp *)
    val mkFuture = mkFut future
 
    (* mkFuture1 : A.exp -> A.exp *)
    val mkFuture1 = mkFut future1 

    local

	(* isFuture : A.exp -> bool *)
	fun isFuture e = (case TypeOf.exp e
			    of T.ConTy (_, c) => TyCon.same (c, futureTyc)
			     | _ => false)

        (* typeOfFuture : A.exp -> T.ty *)
        (* Precondition: The argument must be a future. *)
        (* The function raises Fail if the precondition is not met. *)
        (* ex: typeOfFuture (future (fn () => 8))     ==> int *)
        (* ex: typeOfFuture (future (fn () => 8 > 8)) ==> bool *)
	fun typeOfFuture e =
	    let val t = TypeOf.exp e
		fun mkMsg t = ("typeOfFuture: expected future type, got "
			       ^ (PrintTypes.toString t))
	    in
		case t
		  of T.ConTy ([t'], c) => if TyCon.same (c, futureTyc) 
					  then t'
					  else raise Fail (mkMsg t')
		   | _ => raise Fail (mkMsg t)
	    end

        (* mkTch : var -> A.exp -> A.exp *)
	fun mkTch touchvar e =
	    if (isFuture e) then
		let val t = typeOfFuture e
		    val touch = A.VarExp (touchvar, [t])
		in
		    A.ApplyExp (touch, e, t)
		end
	    else
		let val ts = Var.toString touchvar
		in 
		    raise Fail (ts ^ ": argument is not a future")
		end

	(* mkCan : var -> A.exp -> A.exp *)
	fun mkCan cancelvar e =
	    if (isFuture e) then
		let val cancel = A.VarExp (cancelvar, [typeOfFuture e])
		in
		    A.ApplyExp (cancel, e, Basis.unitTy)
		end
	    else
		let val cs = Var.toString cancelvar
		in
		    raise Fail (cs ^ ": argument is not a future")
		end

    in

    (* mkTouch : A.exp -> A.exp *)
    (* Precondition: The argument must be a future. *)
    (* The function raises Fail if the precondition is not met. *)
    val mkTouch = mkTch touch 

    (* mkTouch1 : A.exp -> A.exp *)
    (* Precondition: The argument must be a future. *)
    (* The function raises Fail if the precondition is not met. *)
    val mkTouch1 = mkTch touch1

    (* mkCancel : A.exp -> A.exp *)
    (* Precondition: The argument e1 must be a future. *)
    (* The function raises Fail if the precondition is not met. *)
    val mkCancel = mkCan cancel

    (* mkCancel1 : A.exp -> A.exp *)
    (* Precondition: The argument e1 must be a future. *)
    (* The function raises Fail if the precondition is not met. *)
    val mkCancel1 = mkCan cancel1

    end (* local *)

  end
