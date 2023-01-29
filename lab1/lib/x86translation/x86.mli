open Core
module AS = Assem

type operation =
  | Add
  | Sub
  | Mul
  | IDiv
  | Mod
  | Mov
  | CLTD

type operand =
  | Imm of Int32.t
  | X86Reg of AS.reg
  | Mem of int
[@@deriving equal]

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

val to_opr : AS.operation -> operation
val format : instr -> string
val __FREE_REG : operand
