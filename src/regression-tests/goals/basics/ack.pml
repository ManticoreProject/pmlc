fun ack(m,n) = if m=0 then
		   n+1
	       else if m>0 andalso n=0 then
		   ack(m-1,1)
	       else if m>0 andalso n>0 then
		   ack(m-1,ack(m,n-1))
	       else
		   raise Fail "undefined"

val _ = Print.printLn (Int.toString (ack (3, 1))) (* should be 13 *)
(*(| ack(4,1), ack(5,0) |)*)

	
