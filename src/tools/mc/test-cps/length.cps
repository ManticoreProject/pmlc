(* length.cps *)

module Length (arg : any, mk : cont(any), exh : cont(any)) =
  fun length (l : any, k : cont(int), exh : cont(any)) = 
    fun len' (l : any, k : cont(int), exh : cont(any)) =
      let tag : int = #0(l)
      if I32Eq(tag, 1 : int) 
        then throw k(0 : int)
        else let cons : any = #1(l)
             let hd : any = #0(cons)
             let tl : any = #1(cons)
             cont k' (i : int) = throw k(I32Add(i, 1 : int))
             apply len' (tl, k', exh)
    cont k''' (i : int) =
      let wi : [int] = wrap(i)
      throw k (wi)
    apply len' (l, k''', exh)
  throw mk(length)
