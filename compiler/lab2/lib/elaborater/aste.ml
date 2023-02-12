module Typ = Ctype

type binop_pure = 
  | Plus
  | Minus
  | Times
  | And
  | Or
  | Leq 
  | Less
  | Geq
  | Greater
  | Eq
  | Neq

type binop_efkt = 
  | Divided_by
  | Modulo
  | ShiftL
  | ShiftR

type unop = 
  | Not

(*_ all subclasses of exp type  *)
type exp = 
  | True 
  | False
  | Var of Symbol.t
  | Const of Int32.t
  | Ternary of 
      { cond : mexp
      ; lb : mexp
      ; rb : mexp
      }
  | PureBinop of  
      { op : binop_pure
      ; lhs : mexp
      ; rhs : mexp
      }
  | EfktBinop of 
      { op : binop_efkt
      ; lhs : mexp
      ; rhs : mexp
      }
  | Unop of 
      { op : unop
      ; operand : mexp;
      }
and mexp = exp Mark.t

type stmt = 
  | Declare of 
      { var : Symbol.t
      ; typ : Typ.t
      ; body : stmt
      }
  | Assign of 
      { var : Symbol.t
      ; exp : exp
      }
  | If of 
      { cond : exp
      ; lb : stmt
      ; rb : stmt}
  | While of 
      { cond : exp
      ; body : stmt
      }
  | Return of exp
  | Nop
  | Seq of stmt * stmt
  | NakedExpr of exp
and program = stmt Mark.t