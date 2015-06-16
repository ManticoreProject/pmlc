(* fls.pml
 *
 * COPYRIGHT (c) 2009 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Implicit local memory for fibers. Each running fiber is associated with at exactly one
 * FLS object. FLS supports a few operations, which are explained below.
 *
 *   - interfacing with the host vproc
 *     Each vproc is assigned one FLS object at a time. Any fiber running on the vproc is
 *     associated with this FLS. The @get field returns the FLS assigned to the host vproc, 
 *     and the @set operation assigns a given FLS to the host vproc.
 *
 *   - pinning
 *     The @pin-to operation marks a fiber as pinned to a particular vproc. Once pinned, a 
 *     fiber should not migrate. The @pin-info operation accesses the pinning information,
 *     which is a valid vproc id if the FLS is pinned. The @pin-to operation marks a given
 *     FLS as pinned to a given vproc id.
 *
 *   - implicit-threading environment (ITE)
 *     The ITE is an extension to FLS that supports threads generated by an implicit-threading
 *     construct. One can access this field via @get-ite or @find-ite, and can initialize this
 *     field via @set-ite.
 *
 *   - dictionary
 *     The dictionary supports extending FLS with arbitrary key / value pairs. In addition, there
 *     are some built-in keys:
 *       -- Topologies (see basis/topologies/)
 * 
 * The representation of FLS contains the fields below.
 *
 *   - vproc id
 *     If this number is a valid vproc id, e.g., in the range [0, ..., p-1], then
 *     the associated fiber is pinned to that vproc. Otherwise the associated fiber
 *     can migrate to other vprocs.
 *
 *   - implicit-threading environment (ITE)
 *     A nonempty value in this field indicates that the fiber represents an implicit
 *     thread.
 *
 *   - dictionary counter
 *     Source for unique ids.
 *
 *   - dictionary
 *     List of key / value pairs.
 *     
 *)

structure FLS :
  sig
(*
    _prim(

    (* environment of an implicit thread; see ../implicit-threading/implicit-thread.pml *)
      typedef ite = [
	  List.list,                    (* work-group stack *)
	  Option.option                 (* current cancelable *)
	];

    (* fiber-local storage *)
      typedef fls = [
	  int,				(* vproc id *)
	  Option.option			(* optional implicit-thread environment (ITE) *)
	];

    (* create fls *)
      define @new (x : unit / exh : exh) : fls;
    (* create a new FLS pinned to the given vproc *)
      define inline @new-pinned (vprocId : int /) : fls;
    (* set the fls on the host vproc *)
      define inline @set (fls : fls / exh : exh) : ();
      define inline @set-in-atomic (self : vproc, fls : fls) : ();
    (* get the fls from the host vproc *)
      define inline @get () : fls;
      define inline @get-in-atomic (self : vproc) : fls;

    (* return the pinning information associated with the given FLS *)
      define @pin-info (fls : fls / exh : exh) : int =
    (* pin the current fiber to the host vproc *)
      define @pin-to (fls : fls, vprocId : int / exh : exh) : fls;

    (* find the ITE (if it exists) *)
      define @get-ite (/ exh : exh) : ite;
      define @find-ite (/ exh : exh) : Option.option;
    (* set the ITE *)
      define @set-ite (ite : ite / exh : exh) : ();

    )
*)

  (** General-purpose dictionary **)

  (* key into the FLS dictionary *)
    type 'a key

  (* create a dictionary key *)
    val newKey : 'a -> 'a key
  (* set value associated with the key *)
    val setKey : 'a key * 'a -> unit
  (* get the value associated with the key *)
    val getKey : 'a key -> 'a Option.option

  (** Built-in dictionary entries **)

    val getTopology : unit -> Topologies.topologies
    val setTopology : Topologies.topologies -> unit

  end = struct

#define VPROC_OFF              0
#define ITE_OFF                1
#define DICT_COUNTER_OFF       2
#define DICT_OFF               3
#define DONE_COMM_OFF          4
#define COUNTER_OFF            5

    val counter = AtomicCounter.new()

    fun getCounter() = counter

    _primcode (

      extern void * M_Print_Int(void *, int);

      typedef key = [int];

    (* WARNING!
      These typedefs (ite and fls) are "known" by the compiler. The C runtime generates a fake version of
      them in vproc/vproc.c, and that _must_ be updated to match any type changes here. Further,
      the layouts of the objects must be mirrored in gc/alloc.c, GlobalAllocNonUniform() and in the type
      header tags defined in codegen/header-tbl-struct.sml. *)

    (* environment of an implicit thread *)
      typedef ite = [
	  List.list,		(* work-group stack *)
	  Option.option		(* current cancelable *)
	];

      (* fiber-local storage *)
      typedef fls = ![
(* FIXME: why not just use the vproc value here (with nil for no pinning? *)
	  int,			(* if this value is a valid vproc id, the thread is pinned to that vproc *)
(* FIXME: using an option type here adds an unnecessary level of indirection *)
	  Option.option,	(* optional implicit-thread environment (ITE) *)
	  int,                  (* dictionary counter *)
	  List.list,            (* dictionary *)
	  ![bool],              (* is the fiber classified as interactive, or computationally intensive? -- Mutable *)
	  int,                  (* thread local counter (used in hybrid STM) *)
	  int
	];

        extern void M_Print_Long(void * , void *);

        define @get-counter = getCounter;

        define @initial-dict() : [int, List.list] = 
        cont dummy(e:exn) = return(alloc(0, nil))
        let counter : AtomicCounter.counter = @get-counter(UNIT / dummy)
        let id : long = AtomicCounter.@bump(counter)
        let id : long = I64LSh(id, 32:long)
        let k0 : [[int], any] = alloc(alloc(DICT_BUILTIN_TOPOLOGY), nil)
        let flg : ![bool] = alloc(false)
        let flg : ![bool] = promote(flg)  
        let k1 : [[int], any] = alloc(alloc(IN_TRANS), flg)
        let k2 : [[int], any] = alloc(alloc(READ_SET), nil)
        let k3 : [[int], any] = alloc(alloc(WRITE_SET), nil)
        let stamp : ![long, int, int, long] = alloc(0:long, 0, 0, id)
        let k4 : [[int], any] = alloc(alloc(STAMP_KEY), stamp)
        let k5 : [[int], any] = alloc(alloc(ABORT_KEY), Option.NONE)
        let k6 : [[int],any] = alloc(alloc(FF_KEY), enum(0):any)
#ifdef COLLECT_STATS        
        let k7 : [[int], any] = alloc(alloc(STATS_KEY), nil)
        let l : List.list = CONS(k7, CONS(k6, CONS(k4, CONS(k3, CONS(k2, CONS(k5, CONS(k0, CONS(k1, nil))))))))
#else
        let l : List.list = CONS(k6, CONS(k4, CONS(k3, CONS(k2, CONS(k5, CONS(k0, CONS(k1, nil)))))))
#endif        
        let ret : [int, List.list] = alloc(7, l)
        return(ret)
      ;

    (* create fls *)
      define inline @new (x : unit / exh : exh) : fls =
          let dict : [int, List.list] = @initial-dict()
	  let dc : ![bool] = alloc(true)
	  let dc : ![bool] = promote(dc)
	  let fls : fls = alloc(~1, Option.NONE, #0(dict), #1(dict), dc, 1, 2)
	  return (fls)
	;

    (* create a new FLS pinned to the given vproc *)
      define inline @new-pinned (vprocId : int) : fls =
          let dict : [int, List.list] = @initial-dict()
	  let dc : ![bool] = alloc(true)
	  let dc : ![bool] = promote(dc)
	  let fls : fls = alloc(vprocId, Option.NONE, #0(dict), #1(dict), dc, 1, 2)
	  return (fls)
	;

    (* set the fls on the host vproc *)
      define inline @set-in-atomic (self : vproc, fls : fls) : () =
	  do assert(NotEqual(fls, nil))
	  do vpstore (CURRENT_FLS, self, fls)
	  return ()
	;

      define inline @set (fls : fls) : () =
(* FIXME: there is a cyclic dependency between this module and SchedulerAction
	  let vp
	  let vp : vproc = SchedulerAction.@atomic-begin()
	  do @set-in-atomic (vp, fls)
	  do SchedulerAction.@atomic-end(vp)
*)
	  do @set-in-atomic (host_vproc, fls)
	  return ()
	;

    (* get the fls from the host vproc *)
      define inline @get () : fls =
	  let fls : fls = vpload (CURRENT_FLS, host_vproc)
	  do assert(NotEqual(fls, nil))
	  return(fls)
	;

      define inline @get-in-atomic (self : vproc) : fls =
	  let fls : fls = vpload (CURRENT_FLS, self)
	  do assert(NotEqual(fls, nil))
	  return(fls)
	;

    (* return the pinning information associated with the given FLS *)
      define inline @pin-info (fls : fls / exh : exh) : int =
	  return(SELECT(VPROC_OFF, fls))
	;

    (* set the fls as pinned to the given vproc *)
      define inline @pin-to (fls : fls, vprocId : int / exh : exh) : fls =
	  let fls : fls = alloc(vprocId, SELECT(ITE_OFF, fls), SELECT(DICT_COUNTER_OFF, fls), 
	                SELECT(DICT_OFF, fls), SELECT(DONE_COMM_OFF, fls), SELECT(COUNTER_OFF, fls), #6(fls))
	  return(fls)
	;

    (* create ite *)
      define @ite (stk : List.list,
		   c : Option.option           (* cancelable *)
		  / exh : exh) : ite =
	  let ite : ite = alloc(stk, c)
	  return(ite)
	;

    (* find the ITE environment *)

      define @find-ite (/ exh : exh) : Option.option =
	  let fls : fls = @get() 
	  return (SELECT(ITE_OFF, fls))
	;

      define @get-ite (/ exh : exh) : ite =
	  let fls : fls = @get()
	  case SELECT(ITE_OFF, fls)
	   of Option.NONE =>
	      let e : exn = Fail(@"FLS.ite: nonexistant implicit threading environment")
	      throw exh(e)
	    | Option.SOME(ite : ite) =>
	      return(ite)
	  end
	;

    (* set the ITE *)
      define @set-ite (ite : ite / exh : exh) : () =
	  let fls : fls = @get()
	  let vprocId : int = @pin-info(fls / exh)
	   let fls : fls = alloc(vprocId, Option.SOME(ite), SELECT(DICT_COUNTER_OFF, fls), SELECT(DICT_OFF, fls), SELECT(DONE_COMM_OFF, fls), SELECT(COUNTER_OFF, fls), #6(fls))
	  do @set(fls)  
	  return()
	;

    (* set the doneComm flag *)
      define @set-done-comm (doneComm : bool / exh : exh) : unit =
	let fls : fls = @get()
	do #0(SELECT(DONE_COMM_OFF, fls)) := doneComm
	return(UNIT)
      ;

    (* get the value of the doneComm flag *)
      define @get-done-comm (/ exh : exh) : bool =
	let fls : fls = @get()
	return (#0(SELECT(DONE_COMM_OFF, fls)))
      ;

      define @keys-same (arg : [[int], [int]] / exh : exh) : bool =
	if I32Eq(#0(#0(arg)), #0(#1(arg))) then return(true) else return(false)
      ;

      define @set-dict (dict : List.list / exh : exh) : unit =
	let fls : fls = @get()
	let fls : fls = alloc(SELECT(VPROC_OFF, fls), SELECT(ITE_OFF, fls), SELECT(DICT_COUNTER_OFF, fls), dict, SELECT(DONE_COMM_OFF, fls), SELECT(COUNTER_OFF, fls), #6(fls))
	do @set(fls)
	return(UNIT)
      ;

      define @get-dict (x : unit / exh : exh) : List.list =
	let fls : fls = @get()
	return(SELECT(DICT_OFF, fls))
      ;

      define @increment-dict-counter () : int =
	let fls : fls = @get()
	let counter : int = SELECT(DICT_COUNTER_OFF, fls)
	let fls : fls = alloc(SELECT(VPROC_OFF, fls), SELECT(ITE_OFF, fls), I32Add(counter, 1), SELECT(DICT_OFF, fls), SELECT(DONE_COMM_OFF, fls), SELECT(COUNTER_OFF, fls), #6(fls))
	do @set(fls)
        return(counter)
      ;

      define @new-key (x : any / exh : exh) : key =
	let counter : int = @increment-dict-counter()
	let wCounter : [int] = alloc(counter)
	let dict : List.list = @get-dict(UNIT / exh)
        let elt : [[int], any] = alloc(wCounter, x)
	let _ : unit = @set-dict(CONS(elt, dict) / exh)
	return(wCounter)
      ;

      define @topology-key (x : unit / exh : exh) : key =
	let k : [int] = alloc(DICT_BUILTIN_TOPOLOGY)
	return(k)
      ;

      define @get-key(k : int / exh : exh) : any = 
            fun getKeyLoop(dict : List.list) : any = case dict
                of CONS(hd : [[int], any], tail : List.list) => 
                    if I32Eq(#0(#0(hd)), k)
                    then return(#1(hd))
                    else apply getKeyLoop(tail)
                |nil => let e : exn = Fail(@"FLS key not found in get-key")
                        do ccall M_Print("FLS key not found in get-key\n")
                        throw exh(e)
                end
            let dict : List.list = @get-dict(UNIT / exh)
            apply getKeyLoop(dict)
        ;

      define @set-key(key : int, v : any / exh : exh) : () = 
            fun setKeyLoop(dict : List.list) : List.list = case dict
                of CONS(hd : [[int], any], tail : List.list) => 
                    if I32Eq(#0(#0(hd)), key)
                    then return(CONS(alloc(alloc(key), v), tail))
                    else let rest : List.list = apply setKeyLoop(tail)
                         return (CONS(hd, rest))
                | nil => let e : exn = Fail(@"FLS key not found in set-key")
                         do ccall M_Print("FLS key not found in set-key\n")
                         throw exh(e)
                end
            let dict : List.list = @get-dict(UNIT / exh)
            let newDict : List.list = apply setKeyLoop(dict)
            let _ : unit = @set-dict(newDict / exh)
            return()
        ;

      (*increment lower 32 bits of thread local counter by n*)
      define inline @inc-counter(n:int) : () = 
        let fls : fls = @get()
        let n' : int = #5(fls)
        do SELECT(COUNTER_OFF, fls) := I32Add(n', n)
        return ();

      (*decrement lower 32 bits of thread local counter by n*)
      define inline @dec-counter(n:int) : () =  
        let fls : fls = @get()
        let n' : int = #5(fls)
        do SELECT(COUNTER_OFF, fls) := I32Sub(n', n)
        return ();

      (*get lower 32 bits of thread local counter by n*)
      define inline @get-counter() : int = 
        let fls : fls = @get()
        let n' : int = #5(fls)
        return(n');

      (*set lower 32 bits of thread local counter by n*)
      define inline @set-counter(n:int) : () = 
        let fls : fls = @get()
        do SELECT(COUNTER_OFF, fls) := n
        return ();

      define inline @set-counter2(n:int) : () = 
        let fls : fls = @get()
        do #6(fls) := n
        return();

      define inline @get-counter2() : int = 
        let fls : fls = @get()
        return(#6(fls));

        

    )

    type 'a key = _prim(key)

    val keysSame : 'a key * 'a key -> bool = _prim(@keys-same)

    val setDict : ('a key * 'a) list -> unit = _prim(@set-dict)

    val getDict : unit -> ('a key * 'a) list = _prim(@get-dict)

    val newKey : 'a -> 'a key = _prim(@new-key)

  (* update a dictionary entry *)
    fun modify (dict, k, x) = (
	  case dict
	   of nil => (raise Fail "FLS.modify: key does not exist in FLS")
	    | (k', x') :: dict =>
	      if keysSame(k, k') then (k, x) :: dict
	      else (k', x') :: modify(dict, k, x)
	  (* end case *))

    fun setKey (k, x) = setDict(modify(getDict(), k, x))

    fun find (dict, k) = (
	  case dict
	   of nil => Option.NONE
	    | (k', x) :: dict =>
	      if keysSame(k, k') then Option.SOME x
	      else find(dict, k)
	  (* end case *))

    fun getKey k = find(getDict(), k)

    val topologyKey : unit -> Topologies.topologies key = _prim(@topology-key)

    fun getTopology () = (
	case getKey(topologyKey())
	 of Option.NONE => (raise Fail "impossible")
	  | Option.SOME x => x
        (* end case *))

    fun setTopology vmap = setKey(topologyKey(), vmap)

  end
