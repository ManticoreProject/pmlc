(* WARNING: this is generated by running 'nowhere x86Peephole.peep'.
 * Do not edit this file directly.
 * Version 1.2.2
 *)

(*#line 20.1 "x86Peephole.peep"*)
functor X86Peephole(
(*#line 21.5 "x86Peephole.peep"*)
                    structure Instr : X86INSTR

(*#line 22.5 "x86Peephole.peep"*)
                    structure Eval : MLTREE_EVAL

(*#line 23.7 "x86Peephole.peep"*)
                    (* sharing Instr.T = Eval.T *)
                    where type T.Basis.cond = Instr.T.Basis.cond
                      and type T.Basis.div_rounding_mode = Instr.T.Basis.div_rounding_mode
                      and type T.Basis.ext = Instr.T.Basis.ext
                      and type T.Basis.fcond = Instr.T.Basis.fcond
                      and type T.Basis.rounding_mode = Instr.T.Basis.rounding_mode
                      and type T.Constant.const = Instr.T.Constant.const
                      and type ('s,'r,'f,'c) T.Extension.ccx = ('s,'r,'f,'c) Instr.T.Extension.ccx
                      and type ('s,'r,'f,'c) T.Extension.fx = ('s,'r,'f,'c) Instr.T.Extension.fx
                      and type ('s,'r,'f,'c) T.Extension.rx = ('s,'r,'f,'c) Instr.T.Extension.rx
                      and type ('s,'r,'f,'c) T.Extension.sx = ('s,'r,'f,'c) Instr.T.Extension.sx
                      and type T.I.div_rounding_mode = Instr.T.I.div_rounding_mode
                      and type T.Region.region = Instr.T.Region.region
                      and type T.ccexp = Instr.T.ccexp
                      and type T.fexp = Instr.T.fexp
                      (* and type T.labexp = Instr.T.labexp *)
                      and type T.mlrisc = Instr.T.mlrisc
                      and type T.oper = Instr.T.oper
                      and type T.rep = Instr.T.rep
                      and type T.rexp = Instr.T.rexp
                      and type T.stm = Instr.T.stm
                   ): PEEPHOLE =
struct

(*#line 26.4 "x86Peephole.peep"*)
   structure I = Instr

(*#line 27.4 "x86Peephole.peep"*)
   structure C = I.C

(*#line 28.4 "x86Peephole.peep"*)
   structure CBase = CellsBasis

(*#line 31.4 "x86Peephole.peep"*)
   fun peephole instrs = 
       let 
(*#line 32.8 "x86Peephole.peep"*)
           fun isStackPtr (I.Direct r) = CBase.sameColor (r, C.esp)
             | isStackPtr _ = false

(*#line 35.8 "x86Peephole.peep"*)
           fun isZeroLE le = (((Eval.valueOf le) = 0) handle _ => false
)

(*#line 37.8 "x86Peephole.peep"*)
           fun isZero (I.Immed n) = n = 0
             | isZero (I.ImmedLabel le) = isZeroLE le
             | isZero _ = false

(*#line 41.8 "x86Peephole.peep"*)
           fun isZeroOpt NONE = true
             | isZeroOpt (SOME opn) = isZero opn

(*#line 44.8 "x86Peephole.peep"*)
           fun loop (code, instrs) = 
               let val v_34 = code
                   fun state_9 (v_0, v_3) = 
                       let val i = v_0
                           and rest = v_3
                       in loop (rest, i :: instrs)
                       end
                   fun state_22 (v_0, v_17, v_3) = 
                       let val le = v_17
                           and rest = v_3
                       in (if (isZeroLE le)
                             then (loop (rest, instrs))
                             else (state_9 (v_0, v_3)))
                       end
                   fun state_51 (v_0, v_1, v_2, v_3) = 
                       (case v_1 of
                         I.Direct v_26 => 
                         let val dst = v_1
                             and rest = v_3
                             and src = v_2
                         in (if (isZero src)
                               then (loop (rest, (I.binary {binOp=I.XORL, src=dst, dst=dst}) :: instrs))
                               else (state_9 (v_0, v_3)))
                         end
                       | _ => state_9 (v_0, v_3)
                       )
               in 
                  (case v_34 of
                    op :: v_33 => 
                    let val (v_0, v_3) = v_33
                    in 
                       (case v_0 of
                         I.INSTR v_32 => 
                         (case v_32 of
                           I.BINARY v_19 => 
                           let val {binOp=v_31, dst=v_1, src=v_2, ...} = v_19
                           in 
                              (case v_31 of
                                I.ADDL => 
                                (case v_2 of
                                  I.Immed v_17 => 
                                  (case v_1 of
                                    I.Direct v_26 => 
                                    (case v_3 of
                                      op :: v_14 => 
                                      let val (v_13, v_4) = v_14
                                      in 
                                         (case v_13 of
                                           I.INSTR v_12 => 
                                           (case v_12 of
                                             I.BINARY v_11 => 
                                             let val {binOp=v_10, dst=v_9, src=v_8, ...} = v_11
                                             in 
                                                (case v_10 of
                                                  I.SUBL => 
                                                  (case v_9 of
                                                    I.Direct v_5 => 
                                                    (case v_8 of
                                                      I.Immed v_7 => 
                                                      let val d_i = v_26
                                                          and d_j = v_5
                                                          and m = v_7
                                                          and n = v_17
                                                          and rest = v_4
                                                      in (if ((CBase.sameColor (d_i, C.esp)) andalso (CBase.sameColor (d_j, C.esp)))
                                                            then (if (m = n)
                                                               then (loop (rest, instrs))
                                                               else (if (m < n)
                                                                  then (loop (rest, (I.binary {binOp=I.ADDL, src=I.Immed (n - m), dst=I.Direct C.esp}) :: instrs))
                                                                  else (loop (rest, (I.binary {binOp=I.SUBL, src=I.Immed (m - n), dst=I.Direct C.esp}) :: instrs))))
                                                            else (state_9 (v_0, v_3)))
                                                      end
                                                    | _ => state_9 (v_0, v_3)
                                                    )
                                                  | _ => state_9 (v_0, v_3)
                                                  )
                                                | _ => state_9 (v_0, v_3)
                                                )
                                             end
                                           | _ => state_9 (v_0, v_3)
                                           )
                                         | _ => state_9 (v_0, v_3)
                                         )
                                      end
                                    | nil => state_9 (v_0, v_3)
                                    )
                                  | _ => state_9 (v_0, v_3)
                                  )
                                | I.ImmedLabel v_17 => state_22 (v_0, v_17, v_3)
                                | _ => state_9 (v_0, v_3)
                                )
                              | I.SUBL => 
                                (case v_2 of
                                  I.Immed v_17 => 
                                  (case v_1 of
                                    I.Direct v_26 => 
                                    (case v_17 of
                                      4 => 
                                      (case v_3 of
                                        op :: v_14 => 
                                        let val (v_13, v_4) = v_14
                                        in 
                                           (case v_13 of
                                             I.INSTR v_12 => 
                                             (case v_12 of
                                               I.MOVE v_11 => 
                                               let val {dst=v_9, mvOp=v_28, src=v_8, ...} = v_11
                                               in 
                                                  (case v_9 of
                                                    I.Displace v_5 => 
                                                    let val {base=v_27, disp=v_30, ...} = v_5
                                                    in 
                                                       (case v_30 of
                                                         I.Immed v_29 => 
                                                         (case v_29 of
                                                           0 => 
                                                           (case v_28 of
                                                             I.MOVL => 
                                                             let val base = v_27
                                                                 and dst_i = v_26
                                                                 and rest = v_4
                                                                 and src = v_8
                                                             in (if (((CBase.sameColor (base, C.esp)) andalso (CBase.sameColor (dst_i, C.esp))) andalso (not (isStackPtr src)))
                                                                   then (loop (rest, (I.pushl src) :: instrs))
                                                                   else (state_9 (v_0, v_3)))
                                                             end
                                                           | _ => state_9 (v_0, v_3)
                                                           )
                                                         | _ => state_9 (v_0, v_3)
                                                         )
                                                       | _ => state_9 (v_0, v_3)
                                                       )
                                                    end
                                                  | _ => state_9 (v_0, v_3)
                                                  )
                                               end
                                             | _ => state_9 (v_0, v_3)
                                             )
                                           | _ => state_9 (v_0, v_3)
                                           )
                                        end
                                      | nil => state_9 (v_0, v_3)
                                      )
                                    | _ => state_9 (v_0, v_3)
                                    )
                                  | _ => state_9 (v_0, v_3)
                                  )
                                | I.ImmedLabel v_17 => state_22 (v_0, v_17, v_3)
                                | _ => state_9 (v_0, v_3)
                                )
                              | _ => state_9 (v_0, v_3)
                              )
                           end
                         | I.LEA v_19 => 
                           let val {addr=v_25, r32=v_20, ...} = v_19
                           in 
                              (case v_25 of
                                I.Displace v_24 => 
                                let val {base=v_22, disp=v_23, ...} = v_24
                                in 
                                   (case v_23 of
                                     I.ImmedLabel v_21 => 
                                     let val base = v_22
                                         and le = v_21
                                         and r32 = v_20
                                         and rest = v_3
                                     in (if ((isZeroLE le) andalso (CBase.sameColor (r32, base)))
                                           then (loop (rest, instrs))
                                           else (state_9 (v_0, v_3)))
                                     end
                                   | _ => state_9 (v_0, v_3)
                                   )
                                end
                              | _ => state_9 (v_0, v_3)
                              )
                           end
                         | I.MOVE v_19 => 
                           let val {dst=v_1, mvOp=v_18, src=v_2, ...} = v_19
                           in 
                              (case v_18 of
                                I.MOVL => 
                                (case v_2 of
                                  I.Displace v_17 => 
                                  let val {base=v_6, disp=v_16, ...} = v_17
                                  in 
                                     (case v_16 of
                                       I.Immed v_15 => 
                                       (case v_15 of
                                         0 => 
                                         (case v_3 of
                                           op :: v_14 => 
                                           let val (v_13, v_4) = v_14
                                           in 
                                              (case v_13 of
                                                I.INSTR v_12 => 
                                                (case v_12 of
                                                  I.BINARY v_11 => 
                                                  let val {binOp=v_10, dst=v_9, src=v_8, ...} = v_11
                                                  in 
                                                     (case v_10 of
                                                       I.ADDL => 
                                                       (case v_9 of
                                                         I.Direct v_5 => 
                                                         (case v_8 of
                                                           I.Immed v_7 => 
                                                           (case v_7 of
                                                             4 => 
                                                             let val base = v_6
                                                                 and dst = v_1
                                                                 and dst_i = v_5
                                                                 and rest = v_4
                                                             in (if (((CBase.sameColor (base, C.esp)) andalso (CBase.sameColor (dst_i, C.esp))) andalso (not (isStackPtr dst)))
                                                                   then (loop (rest, (I.pop dst) :: instrs))
                                                                   else (state_51 (v_0, v_1, v_2, v_3)))
                                                             end
                                                           | _ => state_51 (v_0, v_1, v_2, v_3)
                                                           )
                                                         | _ => state_51 (v_0, v_1, v_2, v_3)
                                                         )
                                                       | _ => state_51 (v_0, v_1, v_2, v_3)
                                                       )
                                                     | _ => state_51 (v_0, v_1, v_2, v_3)
                                                     )
                                                  end
                                                | _ => state_51 (v_0, v_1, v_2, v_3)
                                                )
                                              | _ => state_51 (v_0, v_1, v_2, v_3)
                                              )
                                           end
                                         | nil => state_51 (v_0, v_1, v_2, v_3)
                                         )
                                       | _ => state_51 (v_0, v_1, v_2, v_3)
                                       )
                                     | _ => state_51 (v_0, v_1, v_2, v_3)
                                     )
                                  end
                                | _ => state_51 (v_0, v_1, v_2, v_3)
                                )
                              | _ => state_9 (v_0, v_3)
                              )
                           end
                         | _ => state_9 (v_0, v_3)
                         )
                       | _ => state_9 (v_0, v_3)
                       )
                    end
                  | nil => instrs
                  )
               end
       in loop (instrs, [])
       end
end

