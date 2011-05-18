val itos = Int.toString

fun pr x rng = let
  val n = PArray.length rng
  val _ = Print.print (x ^ ": ")
  in
    if (n<=10) then
      Print.printLn (PArray.tos_int rng)
    else let
      val rLast = rng!(n-1)
      val s = "[|" ^ itos (rng!0) ^ "," ^ itos (rng!1) ^ 
	      ".." ^ itos rLast ^ "|]"
      in
        Print.printLn s
      end
  end

val (x, y, z, w) = ([|1+1 to 10*10 by 2-1|], [|11*11 to 20*20 by 3-2|], 0, "hi")
val a = x
val b = y
val c = z
val d = w

val _ = pr "x" x
val _ = pr "y" y
val _ = pr "a" a
val _ = pr "b" b

val _ = Print.printLn "done"