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

val SOME ((a, b), c) = SOME (([|1 to 10|], [|11 to 20|]), [|21 to 30|])
(*
val x = a
val y = b
val z = c

val _ = pr "a" a
val _ = pr "x" x
val _ = pr "b" b
val _ = pr "y" y
val _ = pr "c" c
val _ = pr "z" z
*)

val _ = Print.printLn "done"