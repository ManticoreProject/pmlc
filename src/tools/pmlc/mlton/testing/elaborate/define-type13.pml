(* FAIL [arity mismatch] *)
_module myId _prim (
  type myType <'a, 'b> = int32;
  type myType' = myType<int32, int32>;
)