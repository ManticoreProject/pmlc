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

val x = [| 2-1 to 5+4 |]
val y = x
val z = [| 1,2,3,4,5,6,7,8,9 |]

val _ = pr "x" x
val _ = pr "y" y
val _ = pr "z" z

val _ = Print.printLn "done"
