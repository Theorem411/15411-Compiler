open Core
module AS = Assem_l4
module R = Register
module V = Graph.Vertex
module Custom = CustomAssembly
(*_ DEBUGGING STAFF  *)

type fspace = X86.instr list
type program = fspace list

let checks_on = true

(* let debug_mode_translate = true *)

let translate_pure get_final = function
  | AS.PureBinop { op; dest = d; lhs; rhs } ->
    let d_final = get_final d in
    let lhs_final = get_final lhs in
    let rhs_final = get_final rhs in
    (match d_final with
    | X86.Reg _ ->
      [ X86.BinCommand { op = Mov; dest = d_final; src = lhs_final }
      ; X86.BinCommand { op = X86.pure_to_opr op; dest = d_final; src = rhs_final }
      ]
    | Stack _ ->
      [ X86.BinCommand { op = Mov; dest = X86.__FREE_REG 4; src = lhs_final }
      ; X86.BinCommand
          { op = X86.pure_to_opr op; dest = X86.__FREE_REG 4; src = rhs_final }
      ; X86.BinCommand { op = Mov; dest = d_final; src = X86.__FREE_REG 4 }
      ]
    | _ -> failwith "X86.Imm can not be a dest")
  | _ -> failwith "not a pure operation"
;;

let translate_efkt (get_final : AS.operand -> X86.operand) (errLabel : Label.t) = function
  (* DIV / MOD *)
  | AS.EfktBinop { op = (Div | Mod) as op; dest = d; lhs; rhs } ->
    let d_final = get_final d in
    let lhs_final = get_final lhs in
    let rhs_final = get_final rhs in
    let right_commands =
      match rhs_final with
      | X86.Imm n ->
        [ X86.BinCommand { op = Mov; dest = X86.Reg R.eax; src = lhs_final }
        ; X86.BinCommand { op = Mov; dest = X86.__FREE_REG 4; src = X86.Imm n }
        ; X86.ZeroCommand { op = X86.Cltd }
        ; X86.UnCommand { op = IDiv; src = X86.__FREE_REG 4 }
        ; X86.BinCommand
            { op = Mov
            ; dest = d_final
            ; src =
                (match op with
                | Div -> X86.Reg R.eax
                | Mod -> X86.Reg { reg = R.EDX; size = 4 }
                | _ -> raise (Failure "it is only Div/Mod case"))
            }
        ]
      | _ ->
        [ X86.BinCommand { op = Mov; dest = X86.Reg R.eax; src = lhs_final }
        ; X86.ZeroCommand { op = X86.Cltd }
        ; X86.UnCommand { op = IDiv; src = rhs_final }
        ; X86.BinCommand
            { op = Mov
            ; dest = d_final
            ; src =
                (match op with
                | Div -> X86.Reg R.eax
                | Mod -> X86.Reg { reg = R.EDX; size = 4 }
                | _ -> raise (Failure "it is only Div/Mod case"))
            }
        ]
    in
    right_commands
  (* SHIFTS using ECX*)
  | AS.EfktBinop { op = (ShiftL | ShiftR) as op; dest = d; lhs; rhs } ->
    let d_final = get_final d in
    let lhs_final = get_final lhs in
    let rhs_final = get_final rhs in
    let right_commands =
      [ X86.BinCommand { op = Mov; dest = X86.__FREE_REG 4; src = lhs_final }
      ; X86.BinCommand
          { op = Mov; dest = X86.Reg { reg = R.ECX; size = 4 }; src = rhs_final }
        (* check for the shift >= 32 *)
      ; X86.Cmp
          { rhs = X86.Reg { reg = R.ECX; size = 4 }; lhs = Imm (Int32.of_int_exn 32) }
      ; X86.Jump { op = Some AS.Jge; label = errLabel }
        (* pre check end *)
        (* check for the shift < 32 *)
      ; X86.Cmp
          { rhs = X86.Reg { reg = R.ECX; size = 4 }; lhs = Imm (Int32.of_int_exn 0) }
      ; X86.Jump { op = Some AS.Jl; label = errLabel }
      ; X86.BinCommand
          { op = X86.efkt_to_opr op
          ; dest = X86.__FREE_REG 4
          ; src = X86.Reg { reg = R.ECX; size = 4 }
          }
      ; X86.BinCommand { op = Mov; dest = d_final; src = X86.__FREE_REG 4 }
      ]
    in
    right_commands
  | _ -> failwith "translate_efkt not implemented yet"
;;

let translate_set get_final = function
  | AS.Set { typ; src } ->
    [ X86.Set { op = typ; src = X86.Reg { reg = R.EAX; size = 4 } }
    ; X86.BinCommand
        { op = Movzx
        ; src = X86.Reg { reg = R.EAX; size = 4 }
        ; dest = X86.Reg { reg = R.EAX; size = 4 }
        }
    ; X86.BinCommand
        { op = Mov; src = X86.Reg { reg = R.EAX; size = 4 }; dest = get_final src }
    ]
  | _ -> failwith "Not a set operation on translate_set"
;;

let translate_call
    (get_final : AS.operand -> X86.operand)
    (fname : string)
    (stack_args : Temp.t list)
  =
  let call = [ X86.Call fname ] in
  if List.length stack_args = 0
  then call
  else (
    let jump_int = List.length stack_args * 8 in
    let jump_size = Int32.of_int_exn jump_int in
    let arg_moves =
      List.concat_mapi
        ~f:(fun i t ->
          let src = get_final (AS.Temp t) in
          let d = X86.Stack (i * 8) in
          match src with
          | Stack mem_i ->
            [ X86.BinCommand
                { op = Mov; dest = X86.__FREE_REG 4; src = X86.Stack (mem_i + jump_int) }
            ; X86.BinCommand { op = Mov; dest = d; src = X86.__FREE_REG 4 }
            ]
          | _ -> [ X86.BinCommand { op = Mov; dest = d; src } ])
        stack_args
    in
    [ X86.BinCommand
        { op = X86.Addq
        ; dest = X86.Reg { reg = R.RSP; size = 8 }
        ; src = X86.Imm jump_size
        }
    ]
    @ call
    @ List.rev arg_moves
    @ [ X86.BinCommand
          { op = X86.Subq
          ; dest = X86.Reg { reg = R.RSP; size = 8 }
          ; src = X86.Imm jump_size
          }
      ])
;;

let translate_cmp get_final = function
  | AS.Cmp (r, l) ->
    let lf = get_final l in
    let rf = get_final r in
    (match lf, rf with
    | X86.Stack _, _ ->
      [ X86.BinCommand { op = Mov; src = lf; dest = X86.__FREE_REG 4 }
      ; X86.Cmp { lhs = X86.__FREE_REG 4; rhs = rf }
      ]
    | _, _ -> [ X86.Cmp { lhs = lf; rhs = rf } ])
  | _ -> failwith "Not a cmp operation on translate_cmp"
;;

let translate_alloc sz =
  [ X86.BinCommand
      { op = Mov
      ; dest = X86.Reg { reg = X86.R.EDI; size = 4 }
      ; src = X86.Imm (Int32.of_int_exn sz)
      }
  ; X86.Call Custom.alloc_fname
  ]
;;

let translate_alloc_array (get_final : AS.operand -> X86.operand) sz (len : AS.operand) =
  let move_to_rsi =
    let len_final = get_final len in
    [ X86.BinCommand
        { op = Mov; dest = X86.Reg { reg = X86.R.ESI; size = 4 }; src = len_final }
    ]
  in
  [ X86.BinCommand
      { op = Mov
      ; dest = X86.Reg { reg = X86.R.EDI; size = 4 }
      ; src = X86.Imm (Int32.of_int_exn sz)
      }
  ]
  @ move_to_rsi
  @ [ X86.Call Custom.alloc_array_fname ]
;;

let translate_check_null
    memErrLabel
    (get_final : AS.operand -> X86.operand)
    (p : AS.local)
  =
  let final = get_final (AS.Local p, 8) in
  match final with
  | Imm _ -> failwith "can not check nullness of an imm"
  | Stack _ ->
    [ X86.BinCommand { op = Movq; dest = X86.__FREE_REG 8; src = final }
    ; X86.Test { rhs = X86.__FREE_REG 8; lhs = X86.__FREE_REG 8 }
    ; X86.Jump { label = memErrLabel; op = Some AS.Je }
    ]
  | Reg _ ->
    [ X86.Test { rhs = final; lhs = final }
    ; X86.Jump { label = memErrLabel; op = Some AS.Je }
    ]
  | Mem _ -> failwith "local can not be memory (on check_null)"
;;

let translate_check_bound
    memErrLabel
    (get_final : AS.operand -> X86.operand)
    ((base, idx) : AS.local * int)
  =
  let head = get_final (AS.Local base, 8) in
  match head with
  | Imm _ -> failwith "can not check bound of an imm"
  | Stack _ ->
    [ X86.BinCommand { op = Mov; dest = X86.__FREE_REG 8; src = head }
    ; X86.BinCommand
        { op = Mov
        ; dest = X86.Reg { reg = R.EAX; size = 4 }
        ; src =
            X86.Mem
              { base_reg = { reg = R.R11D; size = 8 }
              ; disp = Some (-8)
              ; idx_reg = None
              ; scale = None
              }
        }
    ; X86.BinCommand
        { op = Mov; dest = X86.__FREE_REG 4; src = X86.Imm (Int32.of_int_exn idx) }
    ; X86.Test { rhs = X86.__FREE_REG 4; lhs = X86.__FREE_REG 4 }
    ; X86.Jump { label = memErrLabel; op = Some AS.Js }
    ; X86.Cmp { rhs = X86.Reg { reg = R.EAX; size = 4 }; lhs = X86.__FREE_REG 4 }
    ; X86.Jump { label = memErrLabel; op = Some AS.Jle }
    ]
  | Reg { reg; size } ->
    if not (size = 8)
    then failwith "pointer size is not 8"
    else
      [ X86.BinCommand
          { op = Mov
          ; dest = X86.Reg { reg; size = 4 }
          ; src =
              X86.Mem
                { base_reg = { reg; size = 8 }
                ; disp = Some (-8)
                ; idx_reg = None
                ; scale = None
                }
          }
      ; X86.BinCommand
          { op = Mov; dest = X86.__FREE_REG 4; src = X86.Imm (Int32.of_int_exn idx) }
      ; X86.Test { rhs = X86.__FREE_REG 4; lhs = X86.__FREE_REG 4 }
      ; X86.Jump { label = memErrLabel; op = Some AS.Js }
      ; X86.Cmp { rhs = X86.Reg { reg = R.EAX; size = 4 }; lhs = X86.__FREE_REG 4 }
      ; X86.Jump { label = memErrLabel; op = Some AS.Jle }
      ]
  | Mem _ -> failwith "local can not be memory (on check_null)"
;;

let translate_line
    (retLabel, errLabel, memErrLabel)
    (get_final : AS.operand -> X86.operand)
    (prev_lines : X86.instr list)
    (line : AS.instr)
    : X86.instr list
  =
  match line with
  (* Translating move operations *)
  | Mov { dest = d; src = s } ->
    let d_final = get_final d in
    let src_final = get_final s in
    (match d_final, src_final with
    | Stack _, Stack _ ->
      (* mov mem, mem *)
      [ X86.BinCommand { op = Mov; dest = d_final; src = X86.__FREE_REG 4 }
      ; X86.BinCommand { op = Mov; dest = X86.__FREE_REG 4; src = src_final }
      ]
      @ prev_lines
    | Stack _, _ ->
      (* mov mem, mem *)
      [ X86.BinCommand { op = Mov; dest = d_final; src = X86.__FREE_REG 4 }
      ; X86.BinCommand { op = Mov; dest = X86.__FREE_REG 4; src = src_final }
      ]
      @ prev_lines
    | _ -> X86.BinCommand { op = Mov; dest = d_final; src = src_final } :: prev_lines)
  (* Translating pure operations *)
  | AS.PureBinop e ->
    List.rev_append (translate_pure get_final (AS.PureBinop e)) prev_lines
  (* Translating effectful operations *)
  | AS.EfktBinop e ->
    List.rev_append (translate_efkt get_final errLabel (AS.EfktBinop e)) prev_lines
  | Unop { op; dest } ->
    X86.UnCommand { op = X86.unary_to_opr op; src = get_final dest } :: prev_lines
  | Jmp l -> X86.Jump { op = None; label = l } :: prev_lines
  | Cjmp { typ; l } -> X86.Jump { op = Some typ; label = l } :: prev_lines
  | Lab l -> X86.Lbl l :: prev_lines
  | Cmp (r, l) -> List.rev_append (translate_cmp get_final (AS.Cmp (r, l))) prev_lines
  (* Translating comments / directive operations *)
  | AS.Comment d -> Comment d :: prev_lines
  | AS.Directive d -> Directive d :: prev_lines
  | AS.Set s -> List.rev_append (translate_set get_final (AS.Set s)) prev_lines
  | AS.Ret -> [ X86.Ret; X86.Jump { op = None; label = retLabel } ] @ prev_lines
  (* | AS.App _ -> failwith "app is not allowed :(" *)
  | AS.AssertFail -> [ X86.Call "abort" ] @ prev_lines
  | AS.Call { fname; args_overflow = stack_args; _ } ->
    translate_call get_final (Symbol.name fname) stack_args @ prev_lines
  | AS.LoadFromStack _ -> [] @ prev_lines
  | Alloc sz -> List.rev_append (translate_alloc sz) prev_lines
  | Calloc { typ = sz; len } ->
    List.rev_append (translate_alloc_array get_final sz len) prev_lines
  | CheckNull p ->
    if checks_on
    then List.rev_append (translate_check_null memErrLabel get_final p) prev_lines
    else prev_lines
  | CheckBound { base; idx } ->
    if checks_on
    then
      List.rev_append (translate_check_bound memErrLabel get_final (base, idx)) prev_lines
    else prev_lines
;;

let get_error_block errLabel =
  [ X86.Lbl errLabel
  ; X86.Comment "Arithmetic Error Label"
  ; X86.BinCommand
      { op = X86.Mov; dest = X86.Reg { reg = R.EAX; size = 4 }; src = X86.Imm Int32.one }
  ; X86.BinCommand
      { op = X86.Mov; dest = X86.Reg { reg = R.ECX; size = 4 }; src = X86.Imm Int32.zero }
  ; X86.ZeroCommand { op = X86.Cltd }
  ; X86.UnCommand { op = X86.IDiv; src = X86.Reg { reg = R.ECX; size = 4 } }
  ]
;;

let get_memErrLabel_block errLabel =
  [ X86.Lbl errLabel
  ; X86.Comment "Memory Error Label"
  ; X86.BinCommand
      { op = X86.Mov
      ; dest = X86.Reg { reg = R.RDI; size = 4 }
      ; src = X86.Imm (Int32.of_int_exn 12)
      }
  ; X86.Call "raise"
  ]
;;

let translate_function (errLabel, memErrLabel) (fspace : AS.fspace) : X86.instr list =
  match fspace with
  | { fname; fdef_block = fdef_blocks; args = __args } ->
    (* has to be changed to the global one *)
    let reg_map, mem_cell_count = Helper.reg_alloc fdef_blocks in
    let get_final o =
      match o with
      | AS.Imm n, _ -> X86.Imm n
      | _ -> AS.Map.find_exn reg_map o
    in
    let b, e, retLabel = Helper.get_function_be (fname, __args) reg_map mem_cell_count in
    let block_instrs = List.map fdef_blocks ~f:(fun { block; _ } -> block) in
    let translated instructions : X86.instr list =
      List.fold
        instructions
        ~init:[]
        ~f:(translate_line (retLabel, errLabel, memErrLabel) get_final)
    in
    let res = List.concat_map ~f:translated block_instrs in
    let full_rev = List.rev_append e res in
    b @ List.rev full_rev
;;

let translate (fs : AS.program) =
  let arithErrLabel = Label.create () in
  let memErrLabel = Label.create () in
  [ Custom.get_alloc_function memErrLabel ]
  @ [ Custom.get_arrayalloc_function memErrLabel ]
  @ [ get_memErrLabel_block memErrLabel ]
  @ [ get_error_block arithErrLabel ]
  @ List.map ~f:(fun f -> translate_function (arithErrLabel, memErrLabel) f) fs
;;

(* let pp_fspace l = List.map ~f:(X86.format) l
let pp_program l = List.concat_map ~f:pp_fspace l *)
let get_string_list p : X86.instr list = List.concat p
