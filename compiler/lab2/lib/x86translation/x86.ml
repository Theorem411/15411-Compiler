open Core
module AS = Assem

type operand =
  | Imm of Int32.t
  | X86Reg of AS.reg
  | Mem of int
[@@deriving equal, compare, sexp]

let __format_reg = function
  | AS.EAX -> "%eax"
  | AS.EBX -> "%ebx"
  | AS.ECX -> "%ecx"
  | AS.EDX -> "%edx"
  | AS.ESI -> "%esi"
  | AS.EDI -> "%edi"
  | AS.R8D -> "%r8d"
  | AS.R9D -> "%r9d"
  | AS.R10D -> "%r10d"
  | AS.R11D -> "%r11d"
  | AS.R12D -> "%r12d"
  | AS.R13D -> "%r13d"
  | AS.R14D -> "%r14d"
  | AS.R15D -> "%r15d"
  | AS.RBP -> "%rbp"
  | AS.RSP -> "%rsp"
;;

let __format_reg_quad = function
  | AS.EAX -> "%rax"
  | AS.EBX -> "%rbx"
  | AS.ECX -> "%rcx"
  | AS.EDX -> "%rdx"
  | AS.ESI -> "%rsi"
  | AS.EDI -> "%rdi"
  | AS.R8D -> "%r8"
  | AS.R9D -> "%r9"
  | AS.R10D -> "%r10"
  | AS.R11D -> "%r11"
  | AS.R12D -> "%r12"
  | AS.R13D -> "%r13"
  | AS.R14D -> "%r14"
  | AS.R15D -> "%r15"
  | AS.RBP -> "%rbp"
  | AS.RSP -> "%rsp"
;;


(* Mem n means that the varialbe is in -n(%rbp) *)
let format_operand ?(quad=false)= function
  | Imm n -> "$" ^ Int32.to_string n
  | X86Reg r -> if not quad then __format_reg r else __format_reg_quad r
  | Mem n -> string_of_int (4 * n) ^ "(%rsp)"
;;

type operation =
  | Add
  | Sub
  | Subq
  | Addq
  | Mul
  | IDiv
  | Mod
  | Mov
  | Pushq
  | Movq
  | Popq
  | CLTD
[@@deriving equal, compare, sexp]

let format_operation = function
  | Add -> "addl"
  | Sub -> "subl"
  | Addq -> "addq"
  | Subq -> "subq"
  | Mul -> "imull"
  | IDiv -> "idivl"
  | Mov -> "movl"
  | CLTD -> "cltd"
  | Pushq -> "pushq"
  | Popq -> "popq"
  | Movq -> "movq"
  | _ -> raise (Failure "no such operation allowed (yet).")
;;

type instr =
  | BinCommand of
      { op : operation
      ; dest : operand
      ; src : operand
      }
  | UnCommand of
      { op : operation
      ; src : operand
      }
  | Zero of { op : operation }
  | Directive of string
  | Comment of string
  | FunName of string
  | Ret
[@@deriving equal, compare, sexp]

let format = function
| BinCommand {op=Addq|Subq as bop; src=s; dest=d} ->
  sprintf
    "\t%s\t%s, %s"
    (format_operation bop)
    (format_operand ~quad:true s)
    (format_operand ~quad:true d)
  | BinCommand binop ->
    sprintf
      "\t%s\t%s, %s"
      (format_operation binop.op)
      (format_operand binop.src)
      (format_operand binop.dest)
  | UnCommand {op=Pushq|Popq as unop; src=s} ->
    sprintf "\t%s\t%s" (format_operation unop) (format_operand ~quad:true s)
  | UnCommand unop ->
    sprintf "\t%s\t%s" (format_operation unop.op) (format_operand unop.src)
  | Zero z -> sprintf "\t%s" (format_operation z.op)
  | Directive dir -> sprintf "\t%s" dir
  | Comment comment -> sprintf "/* %s */" comment
  | FunName s -> sprintf "%s" s
  | Ret -> sprintf "\t%s" "ret"
;;

let to_opr = function
  | AS.Add -> Add
  | AS.Sub -> Sub
  | AS.Mul -> Mul
  | AS.Div -> IDiv
  | AS.Mod -> Mod
;;

let callee_saved oper =
  match oper with
  | X86Reg r ->
    (match r with
    | AS.EBX | AS.RSP | AS.RBP -> true
    | AS.R12D | AS.R13D | AS.R14D | AS.R15D -> true
    | _ -> false)
  | _ -> raise (Failure "callee_saved can be applied only on X86Reg reg")
;;

let caller_saved oper =
  match oper with
  | X86Reg r ->
    (match r with
    | AS.EAX | AS.EDI | AS.ESI | AS.EDX -> true
    | AS.ECX | AS.R8D | AS.R9D | AS.R10D | AS.R11D -> true
    | _ -> false)
  | _ -> raise (Failure "caller_saved can be applied only on X86Reg reg")
;;

let all_available_regs =
  [ AS.EAX
  ; AS.EDI
  ; AS.ESI
    (*_ not edx before we fix coloring *)
    (*_ ; AS.EDX *)
  ; AS.ECX
  ; AS.R8D
  ; AS.R9D
  ; AS.R10D
  ; AS.EBX
  ; AS.R12D
  ; AS.R13D
  ; AS.R14D
  ; AS.R15D
  ]
;;

let is_reg = function
| X86Reg _ -> true
| _ -> false;;

let __FREE_REG = X86Reg AS.R11D