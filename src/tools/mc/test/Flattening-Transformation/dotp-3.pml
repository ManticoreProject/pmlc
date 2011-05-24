(* stopwatch : (unit -> 'a) -> 'a * Time.time *)
(* Pass in a suspended computation; get back the result and the time it took. *)
(* Note: time is represented as a long. The unit is microseconds. *)
  fun stopwatch thunk = let
    val b = Time.now ()
    val x = thunk ()
    val e = Time.now ()
    in
      (x, e-b)
    end

  fun qs (ns : long list) = (case ns
    of nil => ns
     | q::nil => ns
     | p::ns => let
         val (ls, gs) = List.partition (fn n => n <= p) ns
         in
           (qs ls) @ (p :: (qs gs))
         end
    (* end case *))

  fun med (ns : long list) = let
    val sorted = qs ns
    val len = List.length sorted
    in
      List.nth (sorted, len div 2)
    end

  fun dotp (sv, v) = let
    fun f (i, x) = x * (v!i)
    val m = PArray.map f sv
    fun plus (a:double, b:double) = a+b
    in
      PArray.reduce plus 0.0 m
    end

  fun rnd () = Rand.randDouble (0.0, 1.0)
  
  fun tenToThe n = foldl (fn(m,n)=>m*n) 1 (List.tabulate (n, fn _ => 10))

  val lim = tenToThe 6
  val sparsity = 100
  val times = 10

  fun prcsv ss = Print.printLn (String.concatWith "," ss)

  fun main (n, svTimes, vTimes, pTimes) = 
    if (n <= 0) then let
      val itos = Int.toString
      val tos = Long.toString
      val svMed = med svTimes 
      val vMed = med vTimes    
      val pMed = med pTimes
      in
        prcsv [itos lim, itos (lim div sparsity), tos svMed, tos vMed, tos pMed]     
      end
    else let
      val (testsv, t1) = stopwatch (fn () => [| (i, rnd ()) | i in [| 0 to lim by sparsity |] |])
      val (testv, t2) = stopwatch (fn () => [| rnd () | _ in [| 0 to lim |] |])
      val (testDotp, t3) = stopwatch (fn () => dotp (testsv, testv))
      in
        main (n-1, t1::svTimes, t2::vTimes, t3::pTimes)
      end

  val _ = main (times, nil, nil, nil)

