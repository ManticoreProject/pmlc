(* 
 * 
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Print Code for the Garbage Collector Scan files
 *)

structure PrintTable = 
struct
    
    (* number of predefined table entries, important for the table length!! *)
    val predefined = 3
    
    (* Headerfiles *)
    fun header (MyoutStrm) = (  
        TextIO.output (MyoutStrm, "#include <stdint.h>\n");
        TextIO.output (MyoutStrm, "#include <stdio.h>\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "#include \"gc-scan.h\"\n");
        TextIO.output (MyoutStrm, "#include \"gc-inline.h\"\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "\n");
        ()
        )
    
    (*Minor GC Functions *)
    fun minorpre (MyoutStrm) = (
        TextIO.output (MyoutStrm, "Word_t * minorGCscanRAWpointer (Word_t* ptr, Word_t **nextW, Addr_t allocSzB, Addr_t nurseryBase) {\n");
        TextIO.output (MyoutStrm, "\n" );
        TextIO.output (MyoutStrm, "assert (isRawHdr(ptr[-1]));\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "  }\n");
        
        TextIO.output (MyoutStrm, "Word_t * minorGCscanVECTORpointer (Word_t* ptr, Word_t **nextW, Addr_t allocSzB, Addr_t nurseryBase) {\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "Word_t *nextScan = ptr;\n");
        TextIO.output (MyoutStrm, "  int len = GetLength(ptr[-1]);\n" );
        TextIO.output (MyoutStrm, "  for (int i = 0;  i < len;  i++, nextScan++) {\n");
        TextIO.output (MyoutStrm, "   Value_t v = *(Value_t *)nextScan;\n");
        TextIO.output (MyoutStrm, "   if (isPtr(v)) {\n");
        TextIO.output (MyoutStrm, "      if (inAddrRange(nurseryBase, allocSzB, ValueToAddr(v))) {\n");
        TextIO.output (MyoutStrm, "          *nextScan = (Word_t)ForwardObjMinor(v, nextW);\n");
        TextIO.output (MyoutStrm, "      }\n");
        TextIO.output (MyoutStrm, "    }\n");
        TextIO.output (MyoutStrm, "   }\n");
		TextIO.output (MyoutStrm, "return (ptr+len);\n");
        TextIO.output (MyoutStrm, "}\n");
        TextIO.output (MyoutStrm, "\n");
		
		TextIO.output (MyoutStrm, "Word_t * minorGCscanPROXYpointer (Word_t* ptr, Word_t **nextW, Addr_t allocSzB, Addr_t nurseryBase) {\n");
		TextIO.output (MyoutStrm, "//assert (isProxyHdr(ptr[-1]));\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "  }\n");
		
		()
        )


    
    fun minor (MyoutStrm) = let
        val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
        fun printmystring [] = ()
          | printmystring ((a,b)::t) = (let
                
				val size = String.size a
                fun lp(0,bites,pos) = ()
                | lp(strlen,bites,pos) =(
                    if (String.compare (substring(bites,strlen-1,1),"1") = EQUAL)
                    then (
                        TextIO.output (MyoutStrm,concat["    v = *(scanP+",Int.toString pos,");\n"]);
                        TextIO.output (MyoutStrm,"   if (inAddrRange(nurseryBase, allocSzB, ValueToAddr(v))) {\n");
                        TextIO.output (MyoutStrm,concat["     *(scanP+",Int.toString pos,") = ForwardObjMinor(v, nextW);\n"]);
                        TextIO.output (MyoutStrm,"  }\n");
                        lp(strlen-1,bites,pos+1)
                        )
                    else 
                        lp(strlen-1,bites,pos+1)
                    )
                in
                TextIO.output (MyoutStrm, concat["Word_t * minorGCscan",Int.toString b,"pointer (Word_t* ptr, Word_t **nextW, Addr_t allocSzB, Addr_t nurseryBase) {\n"]);
                TextIO.output (MyoutStrm, "  \n");
                TextIO.output (MyoutStrm, "  Value_t *scanP = (Value_t *)ptr;\n");
                TextIO.output (MyoutStrm, "  Value_t v = *scanP;\n");
                TextIO.output (MyoutStrm, "\n");
                
                lp(size,a,0);
                
				TextIO.output (MyoutStrm, concat["return (ptr+",Int.toString size,");\n"]);
                TextIO.output (MyoutStrm, "}\n");
                TextIO.output (MyoutStrm, "\n"); 
                
                printmystring t
                end
            )
            
    in
        printmystring s;
        ()
    end

    (*Polymorphic Equality functions *)
    
    fun polyEqPre (MyoutStrm) = (
        TextIO.output (MyoutStrm, "bool polyEqRAWpointer (Word_t * ptr1, Word_t * ptr2) {\n");
	TextIO.output (MyoutStrm, "    if(!isPtr((Value_t)ptr2)){\n\t\tprintf(\"ptr2 is not a pointer and ptr1 is\\n\");\n\t\treturn false;\n\t}\n");
	TextIO.output (MyoutStrm, "    if(ptr1[-1] != ptr2[-1]){\n\t\tprintf(\"RAW: headers not equal\\n\");\n\t\treturn false;\n\t}\n");
	TextIO.output (MyoutStrm, "    int len = GetLength(ptr1[-1]);\n");
	TextIO.output (MyoutStrm, "    for(int i = 0; i < len; i++){\n");
	TextIO.output (MyoutStrm, "        if(ptr1[i] != ptr2[i]){\n\t\t\tprintf(\"RAW: differed on  element %d of %d, (%lu, %lu) (%lu, %lu)\\n\", i, len, ptr1[i], ptr2[i], (Word_t)ptr1, (Word_t)ptr2); return false;\n\t\t}\n");
	TextIO.output (MyoutStrm, "    }\n");
	TextIO.output (MyoutStrm, "    return true;\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "}\n");
        
        TextIO.output (MyoutStrm, "bool polyEqVECTORpointer (Word_t* ptr1, Word_t * ptr2) {\n");
	TextIO.output (MyoutStrm, "    if(!isPtr((Value_t)ptr2)){\n\t\tprintf(\"ptr2 is not a pointer and ptr1 is\\n\");\n\t\treturn false;\n\t}\n");
        TextIO.output (MyoutStrm, "    if(ptr1[-1] != ptr2[-1]){\n\t\tprintf(\"VECTOR: headers not equal\\n\");\n\t\treturn false;\n\t}\n");
	TextIO.output (MyoutStrm, "    int len = GetLength(ptr1[-1]);\n");
	TextIO.output (MyoutStrm, "    for(int i = 0; i < len; i++){\n");
	TextIO.output (MyoutStrm, "        if(ptr1[i] != ptr2[i] && (!isPtr((Value_t)ptr1[i]) || !table[getID(((Word_t* )ptr1[i])[-1])].polyEq((Word_t* )ptr1[i], (Word_t* )ptr2[i]))){\n");
	TextIO.output (MyoutStrm, "            printf(\"VECTOR: Failed on element %d\\n\", i);\n");
	TextIO.output (MyoutStrm, "            return false;\n");
	TextIO.output (MyoutStrm, "        }\n");
	TextIO.output (MyoutStrm, "    }\n");
	TextIO.output (MyoutStrm, "    return true;\n");
        TextIO.output (MyoutStrm, "}\n");
		
	TextIO.output (MyoutStrm, "bool polyEqPROXYpointer (Word_t* ptr1, Word_t * ptr2) {\n");
	TextIO.output (MyoutStrm, "    printf(\"Warning: inside polyEqPROXYpointer\\n\");\n");
	TextIO.output (MyoutStrm, "    return false;\n");
        TextIO.output (MyoutStrm, "}\n")
        )

    fun polyEq(MyoutStrm) = let
	val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
	fun printMyString [] = ()
	  | printMyString ((a,b)::t) = let
	      val size = String.size a
	      fun lp(0, bites, pos) = ()
		| lp(strlen, bites, pos) = 
		  if String.compare(substring(bites, strlen-1, 1), "1") = EQUAL
		  then 
		      let
			  val p = Int.toString pos
		      in
			  TextIO.output(MyoutStrm, concat["    if(ptr1[", p, "] != ptr2[", p, "] && (!isPtr((Value_t)ptr1[", p ,"])  || !table[getID(((Word_t* )ptr1[", p, "])[-1])].polyEq((Word_t* )ptr1[", p, "], (Word_t* )ptr2[", p, "]))){\n"]);
			  TextIO.output (MyoutStrm, concat["        if(!isPtr((Value_t)ptr1[",p,"]))\n"]);
			  TextIO.output (MyoutStrm, concat["            printf(\"polyEq", Int.toString b, ": Failed on element ", p , ", because it is not a pointer\\n\");\n"]);
			  TextIO.output (MyoutStrm, concat["        else printf(\"polyEq", Int.toString b, ": Failed on element ", p , ", because it is not recursively equal\\n\");\n"]);
			  TextIO.output(MyoutStrm, "        return false;\n");
			  TextIO.output (MyoutStrm, "    }\n");
			  lp(strlen-1,bites,pos+1)
		      end
                  else
		      let val p = Int.toString pos
		      in TextIO.output (MyoutStrm, concat["    if(ptr1[", p, "] != ptr2[", p, "]){\n\t\tprintf(\"polyEq", Int.toString b, ": Failed on RAW element ", p, " because they are not bit equal (%lu, %lu)\\n\", ptr1[", p, "], ptr2[", p, "]);\n"]);
			 TextIO.output (MyoutStrm, "        return false;\n\t}\n");
			 lp(strlen-1,bites,pos+1)
		      end
              
	  in
	      TextIO.output (MyoutStrm, concat["bool polyEq",Int.toString b,"pointer (Word_t* ptr1, Word_t* ptr2) {\n"]);
	      TextIO.output (MyoutStrm, "    if(!isPtr((Value_t)ptr2)){\n\t\tprintf(\"ptr2 is not a pointer, and ptr1 is\\n\");\n\t\treturn false;\n\t}\n");
	      TextIO.output (MyoutStrm, concat["\tif(ptr1[-1] != ptr2[-1]){\n\t\tprintf(\"polyEq", Int.toString b, ": headers are not equal\\n\");\n\t\treturn false;\n\t}\n"]);
	      lp(size, a, 0);
	      TextIO.output (MyoutStrm, "    return true;\n");
              TextIO.output (MyoutStrm, "}\n");
              TextIO.output (MyoutStrm, "\n");   
              printMyString t
          end
    in
        printMyString s;
        ()
    end
(*
    fun polyEqPre (MyoutStrm) = (
        TextIO.output (MyoutStrm, "bool polyEqRAWpointer (Word_t * ptr1, Word_t * ptr2) {\n");
	TextIO.output (MyoutStrm, "    if(!isPtr((Value_t)ptr2))\n\t\treturn 0;\n");
	TextIO.output (MyoutStrm, "    if(ptr1[-1] != ptr2[-1])\n        return false;\n");
	TextIO.output (MyoutStrm, "    int len = GetLength(ptr1[-1]);\n");
	TextIO.output (MyoutStrm, "    for(int i = 0; i < len; i++){\n");
	TextIO.output (MyoutStrm, "        if(ptr1[i] != ptr2[i]){\n\t\t\treturn false;\n\t\t}\n");
	TextIO.output (MyoutStrm, "    }\n");
	TextIO.output (MyoutStrm, "    return true;\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "}\n");
        
        TextIO.output (MyoutStrm, "bool polyEqVECTORpointer (Word_t* ptr1, Word_t * ptr2) {\n");
	TextIO.output (MyoutStrm, "    if(!isPtr((Value_t)ptr2))\n\t\treturn 0;\n");
        TextIO.output (MyoutStrm, "    if(ptr1[-1] != ptr2[-1])\n        return false;\n");
	TextIO.output (MyoutStrm, "    int len = GetLength(ptr1[-1]);\n");
	TextIO.output (MyoutStrm, "    for(int i = 0; i < len; i++){\n");
	TextIO.output (MyoutStrm, "        if(ptr1[i] != ptr2[i] && (!isPtr((Value_t)ptr1[i]) || !table[getID(((Word_t* )ptr1[i])[-1])].polyEq((Word_t* )ptr1[i], (Word_t* )ptr2[i]))){\n");
	TextIO.output (MyoutStrm, "            return false;\n");
	TextIO.output (MyoutStrm, "        }\n");
	TextIO.output (MyoutStrm, "    }\n");
	TextIO.output (MyoutStrm, "    return true;\n");
        TextIO.output (MyoutStrm, "}\n");
		
	TextIO.output (MyoutStrm, "bool polyEqPROXYpointer (Word_t* ptr1, Word_t * ptr2) {\n");
	TextIO.output (MyoutStrm, "    printf(\"Warning: inside polyEqPROXYpointer\\n\");\n");
	TextIO.output (MyoutStrm, "    return false;\n");
        TextIO.output (MyoutStrm, "}\n")
        )

    fun polyEq(MyoutStrm) = let
	val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
	fun printMyString [] = ()
	  | printMyString ((a,b)::t) = let
	      val size = String.size a
	      fun lp(0, bites, pos) = ()
		| lp(strlen, bites, pos) = 
		  if String.compare(substring(bites, strlen-1, 1), "1") = EQUAL
		  then 
		      let
			  val p = Int.toString pos
		      in
			  TextIO.output(MyoutStrm, concat["    if(ptr1[", p, "] != ptr2[", p, "] && (!isPtr((Value_t)ptr1[", p ,"])  || !table[getID(((Word_t* )ptr1[", p, "])[-1])].polyEq((Word_t* )ptr1[", p, "], (Word_t* )ptr2[", p, "]))){\n"]);
			  TextIO.output(MyoutStrm, "        return false;\n");
			  TextIO.output (MyoutStrm, "    }\n");
			  lp(strlen-1,bites,pos+1)
		      end
                  else
		      let val p = Int.toString pos
		      in TextIO.output (MyoutStrm, concat["    if(ptr1[", p, "] != ptr2[", p, "])\n"]);
			 TextIO.output (MyoutStrm, "        return false;\n");
			 lp(strlen-1,bites,pos+1)
		      end
              
	  in
	      TextIO.output (MyoutStrm, concat["bool polyEq",Int.toString b,"pointer (Word_t* ptr1, Word_t* ptr2) {\n"]);
	      TextIO.output (MyoutStrm, "    if(ptr2 == (Word_t* ) 1)\n\t\treturn 0;\n");
	      TextIO.output (MyoutStrm, "    if(ptr1[-1] != ptr2[-1])\n        return false;\n");
	      lp(size, a, 0);
	      TextIO.output (MyoutStrm, "    return true;\n");
              TextIO.output (MyoutStrm, "}\n");
              TextIO.output (MyoutStrm, "\n");   
              printMyString t
          end
    in
        printMyString s;
        ()
    end
	*)	  
    (*Major GC Functions *)
    fun majorpre (MyoutStrm) = (
        TextIO.output (MyoutStrm, "Word_t * majorGCscanRAWpointer (Word_t* ptr, VProc_t *vp, Addr_t oldSzB, Addr_t heapBase) {\n");
        TextIO.output (MyoutStrm, "\n" );
        TextIO.output (MyoutStrm, "assert (isRawHdr(ptr[-1]));\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "  }\n");
        
        TextIO.output (MyoutStrm, "Word_t * majorGCscanVECTORpointer (Word_t* ptr, VProc_t *vp, Addr_t oldSzB, Addr_t heapBase) {\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "Word_t *nextScan = ptr;\n");
        TextIO.output (MyoutStrm, "  int len = GetLength(ptr[-1]);\n" );
        TextIO.output (MyoutStrm, "  for (int i = 0;  i < len;  i++, nextScan++) {\n");
        TextIO.output (MyoutStrm, "   Value_t v = *(Value_t *)nextScan;\n");
        TextIO.output (MyoutStrm, "   if (isPtr(v)) {\n");
        TextIO.output (MyoutStrm, "     if (inAddrRange(heapBase, oldSzB, ValueToAddr(v))) {\n");
        TextIO.output (MyoutStrm, "          *nextScan = (Word_t)ForwardObjMajor(vp, v);\n");
        TextIO.output (MyoutStrm, "      }\n");
        TextIO.output (MyoutStrm, "      else if (inVPHeap(heapBase, (Addr_t)v)) {\n");
        TextIO.output (MyoutStrm, "          // p points to another object in the \"young\" region,\n");
        TextIO.output (MyoutStrm, "          // so adjust it.\n");
        TextIO.output (MyoutStrm, "          *nextScan = (Word_t)((Addr_t)v - oldSzB);\n");
        TextIO.output (MyoutStrm, "       }\n");
        TextIO.output (MyoutStrm, "    }\n");
        TextIO.output (MyoutStrm, "   }\n");
		TextIO.output (MyoutStrm, "return (ptr+len);\n");
        TextIO.output (MyoutStrm, "}\n");
        TextIO.output (MyoutStrm, "\n");
		
		TextIO.output (MyoutStrm, "Word_t * majorGCscanPROXYpointer (Word_t* ptr, VProc_t *vp, Addr_t oldSzB, Addr_t heapBase) {\n");
        TextIO.output (MyoutStrm, "//assert (isProxyHdr(ptr[-1]));\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "  }\n");
        ()
        )


    
    fun major (MyoutStrm) = let
        val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
        fun printmystring [] = ()
            | printmystring ((a,b)::t) = (let
                    
				val size = String.size a	
                fun lp(0,bites,pos) = ()
                | lp(strlen,bites,pos) =(
                    if (String.compare (substring(bites,strlen-1,1),"1") = EQUAL)
                    then (
                        TextIO.output (MyoutStrm,concat["    v = *(Value_t *)(scanP+",Int.toString pos,");\n"]);
                        TextIO.output (MyoutStrm,"   if (inAddrRange(heapBase, oldSzB, ValueToAddr(v))) {\n");
                        TextIO.output (MyoutStrm,concat["     *(scanP+",Int.toString pos,") = (Word_t)ForwardObjMajor(vp, v);\n"]);
                        TextIO.output (MyoutStrm,"  }\n");
                        TextIO.output (MyoutStrm,"  else if (inVPHeap(heapBase, ValueToAddr(v))) {\n");
                        TextIO.output (MyoutStrm,concat["      *(scanP+",Int.toString pos,") = (Word_t)AddrToValue(ValueToAddr(v) - oldSzB);\n"]);
                        TextIO.output (MyoutStrm,"   }\n");
                        
                        lp(strlen-1,bites,pos+1)
                        )
                    else 
                        lp(strlen-1,bites,pos+1)
                    )
                in
                TextIO.output (MyoutStrm, concat["Word_t * majorGCscan",Int.toString b,"pointer (Word_t* ptr, VProc_t *vp, Addr_t oldSzB, Addr_t heapBase) {\n"]);
                TextIO.output (MyoutStrm, "  \n");
                TextIO.output (MyoutStrm, "  Word_t *scanP = ptr;\n");
                TextIO.output (MyoutStrm, "  Value_t v = *(Value_t *)scanP;\n");
                TextIO.output (MyoutStrm, "\n");
                
                lp(size,a,0);
                
				TextIO.output (MyoutStrm, concat["return (ptr+",Int.toString size,");\n"]);
                TextIO.output (MyoutStrm, "}\n");
                TextIO.output (MyoutStrm, "\n"); 
                
                printmystring t
                end
            )
            
    in
        printmystring s;
        ()
    end
    
    
        
    (*Globaltospace GC Functions *)
    fun globaltospacepre (MyoutStrm) = (
        TextIO.output (MyoutStrm, "Word_t * ScanGlobalToSpaceRAWfunction (Word_t* ptr, VProc_t *vp, Addr_t heapBase)  {\n");
        TextIO.output (MyoutStrm, "\n" );
        TextIO.output (MyoutStrm, "assert (isRawHdr(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "  }\n");
        
        TextIO.output (MyoutStrm, "Word_t * ScanGlobalToSpaceVECTORfunction (Word_t* ptr, VProc_t *vp, Addr_t heapBase) {\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "Word_t *nextScan = ptr;\n");
        TextIO.output (MyoutStrm, "  int len = GetLength(ptr[-1]);\n" );
        TextIO.output (MyoutStrm, "  for (int i = 0;  i < len;  i++, nextScan++) {\n");
        TextIO.output (MyoutStrm, "   Value_t v = *(Value_t *)nextScan;\n");
        TextIO.output (MyoutStrm, "     if (isPtr(v) && inVPHeap(heapBase, ValueToAddr(v))) {\n");
        TextIO.output (MyoutStrm, "          *nextScan = (Word_t)ForwardObjGlobal(vp, v);\n");
        TextIO.output (MyoutStrm, "      }\n");
        TextIO.output (MyoutStrm, "    }\n");
		TextIO.output (MyoutStrm, "return (ptr+len);\n");
        TextIO.output (MyoutStrm, "}\n");
        TextIO.output (MyoutStrm, "\n");
		
		TextIO.output (MyoutStrm, "Word_t * ScanGlobalToSpacePROXYfunction (Word_t* ptr, VProc_t *vp, Addr_t heapBase)  {\n");
        TextIO.output (MyoutStrm, "//assert (isProxyHdr(ptr[-1]));\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "  }\n");
        ()
        )


    
    fun globaltospace (MyoutStrm) = let
        val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
        fun printmystring [] = ()
            | printmystring ((a,b)::t) = (let
                    
				val size = String.size a	
                fun lp(0,bites,pos) = ()
                | lp(strlen,bites,pos) =(
                    if (String.compare (substring(bites,strlen-1,1),"1") = EQUAL)
                    then (
                        TextIO.output (MyoutStrm,concat["    v = *(Value_t *)(scanP+",Int.toString pos,");\n"]);
                        TextIO.output (MyoutStrm,"   if (inVPHeap(heapBase, ValueToAddr(v))) {\n");
                        TextIO.output (MyoutStrm,concat["     *(scanP+",Int.toString pos,") = (Word_t)ForwardObjGlobal(vp, v);\n"]);
                        TextIO.output (MyoutStrm,"  }\n");
                        
                        lp(strlen-1,bites,pos+1)
                        )
                    else 
                        lp(strlen-1,bites,pos+1)
                    )
                in
                TextIO.output (MyoutStrm, concat["Word_t * ScanGlobalToSpace",Int.toString b,"function (Word_t* ptr, VProc_t *vp, Addr_t heapBase) {\n"]);
                TextIO.output (MyoutStrm, "  \n");
                TextIO.output (MyoutStrm, "  Word_t *scanP = ptr;\n");
                TextIO.output (MyoutStrm, "  Value_t v = *(Value_t *)scanP;\n");
                TextIO.output (MyoutStrm, "\n");
                
                lp(size,a,0);
                
				TextIO.output (MyoutStrm, concat["return (ptr+",Int.toString size,");\n"]);
                TextIO.output (MyoutStrm, "}\n");
                TextIO.output (MyoutStrm, "\n"); 
                
                printmystring t
                end
            )
            
    in
        printmystring s;
        ()
    end

    
    (*Global GC Functions *)
    fun globalpre (MyoutStrm) = (
        TextIO.output (MyoutStrm, "Word_t * globalGCscanRAWpointer (Word_t* ptr, VProc_t *vp) {\n");
        TextIO.output (MyoutStrm, "\n" );
        TextIO.output (MyoutStrm, "assert (isRawHdr(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "}\n");
        
        TextIO.output (MyoutStrm, "Word_t * globalGCscanVECTORpointer (Word_t* ptr, VProc_t *vp) {\n");
        TextIO.output (MyoutStrm, "\n");
        TextIO.output (MyoutStrm, "Word_t *nextScan = ptr;\n");
        TextIO.output (MyoutStrm, "  int len = GetLength(ptr[-1]);\n" );
        TextIO.output (MyoutStrm, "  for (int i = 0;  i < len;  i++, nextScan++) {\n");
        TextIO.output (MyoutStrm, "   Value_t v = *(Value_t *)nextScan;\n");
        TextIO.output (MyoutStrm, "   if (isFromSpacePtr(v)) {\n");
        TextIO.output (MyoutStrm, "          *nextScan = (Word_t)ForwardObjGlobal(vp, v);\n");
        TextIO.output (MyoutStrm, "    }\n");
        TextIO.output (MyoutStrm, "   }\n");
		TextIO.output (MyoutStrm, "return (ptr+len);\n");
        TextIO.output (MyoutStrm, "}\n");
        TextIO.output (MyoutStrm, "\n");
		
		TextIO.output (MyoutStrm, "Word_t * globalGCscanPROXYpointer (Word_t* ptr, VProc_t *vp) {\n");
        TextIO.output (MyoutStrm, "//assert (isProxyHdr(ptr[-1]));\n");
		TextIO.output (MyoutStrm, "return (ptr+GetLength(ptr[-1]));\n");
        TextIO.output (MyoutStrm, "  }\n");
        ()
        )


    
    fun global (MyoutStrm) = let
        val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
        fun printmystring [] = ()
            | printmystring ((a,b)::t) = (let
                    
				val size = String.size a	
                fun lp(0,bites,pos) = ()
                | lp(strlen,bites,pos) =(
                    if (String.compare (substring(bites,strlen-1,1),"1") = EQUAL)
                    then (
                        TextIO.output (MyoutStrm,concat["    v = *(Value_t *)(scanP+",Int.toString pos,");\n"]);
                        TextIO.output (MyoutStrm,"   if (isFromSpacePtr(v)) {\n");
                        TextIO.output (MyoutStrm,concat["     *(scanP+",Int.toString pos,") = (Word_t)ForwardObjGlobal(vp, v);\n"]);
                        TextIO.output (MyoutStrm,"  }\n");
                        lp(strlen-1,bites,pos+1)
                        )
                    else 
                        lp(strlen-1,bites,pos+1)
                    )
                in
                TextIO.output (MyoutStrm, concat["Word_t * globalGCscan",Int.toString b,"pointer (Word_t* ptr, VProc_t *vp) {\n"]);
                TextIO.output (MyoutStrm, "  \n");
                TextIO.output (MyoutStrm, "  Word_t *scanP = ptr;\n");
                TextIO.output (MyoutStrm, "  Value_t v = *(Value_t *)scanP;\n");
                TextIO.output (MyoutStrm, "\n");
                
                lp(size,a,0);
                
				TextIO.output (MyoutStrm, concat["return (ptr+",Int.toString size,");\n"]);
                TextIO.output (MyoutStrm, "}\n");
                TextIO.output (MyoutStrm, "\n"); 
                
                printmystring t
                end
            )
            
    in
        printmystring s;
        ()
    end
    
    fun createtable (MyoutStrm) = (let
        val s = HeaderTableStruct.HeaderTable.print (HeaderTableStruct.header)
        val length = List.length s
        
        fun printtable (listlength,i) = (
            if (listlength = i)
            then ()
            else (
                TextIO.output (MyoutStrm, concat[",{minorGCscan",Int.toString i,"pointer,majorGCscan",Int.toString i,"pointer,globalGCscan",Int.toString i,"pointer,ScanGlobalToSpace",Int.toString i,"function, polyEq", Int.toString i, "pointer}\n"]);
                printtable(listlength,i+1)
                )
            )
            
        in
        TextIO.output (MyoutStrm, concat["tableentry table[",Int.toString (length+predefined),"] = { {minorGCscanRAWpointer,majorGCscanRAWpointer,globalGCscanRAWpointer,ScanGlobalToSpaceRAWfunction, polyEqRAWpointer},\n"]);
        TextIO.output (MyoutStrm, "{minorGCscanVECTORpointer,majorGCscanVECTORpointer,globalGCscanVECTORpointer,ScanGlobalToSpaceVECTORfunction, polyEqVECTORpointer},\n");
	TextIO.output (MyoutStrm, "{minorGCscanPROXYpointer,majorGCscanPROXYpointer,globalGCscanPROXYpointer,ScanGlobalToSpacePROXYfunction, polyEqPROXYpointer}\n");
        printtable (length+predefined,predefined);        
        TextIO.output (MyoutStrm," };\n"); 
        TextIO.output (MyoutStrm,"\n");
        
        ()
        end
        )        
    
    fun print (path) = let
            val Myout = TextIO.openOut path handle e => (print "OPEN FAILED\n\n\n"; raise e)
        in
            header Myout;
            
            minorpre Myout;
            minor Myout;
            
            majorpre Myout;
            major Myout;
            
            globaltospacepre Myout;
            globaltospace Myout;
            
            globalpre Myout;
            global Myout;
            
	    polyEqPre Myout;
	    polyEq Myout;

            createtable Myout;
            
            TextIO.closeOut(Myout)
        end
    
end
    
