%{
(* L1 Compiler
 * L1 grammar
 * Author: Kaustuv Chaudhuri <kaustuv+@cs.cmu.edu>
 * Modified: Frank Pfenning <fp@cs.cmu.edu>
 *
 * Modified: Anand Subramanian <asubrama@andrew.cmu.edu> Fall 2010
 * Now conforms to the L1 fragment of C0
 *
 * Modified: Maxime Serrano <mserrano@andrew.cmu.edu> Fall 2014
 * Should be more up-to-date with 2014 spec
 *
 * Modified: Alice Rao <alrao@andrew.cmu.edu> Fall 2017
 *   - Update to use Core instead of Core.Std and ppx
 *
 * Modified: Nick Roberts <nroberts@alumni.cmu.edu>
 *   - Update to use menhir instead of ocamlyacc.
 *   - Improve presentation of marked asts.
 *
 * Converted to OCaml by Michael Duggan <md5i@cs.cmu.edu>
 *)

let mark
  (data : 'a)
  (start_pos : Lexing.position)
  (end_pos : Lexing.position) : 'a Mark.t =
  let src_span = Mark.of_positions start_pos end_pos in
  Mark.mark data src_span
%}

%token Eof
%token Semicolon
%token <Int32.t> Dec_const
%token <Int32.t> Hex_const
%token <Symbol.t> Ident
%token Return
%token Int Bool
%token True False
%token Main
%token If Else While For
%token Plus Minus Star Slash Percent
%token Assign Plus_eq Minus_eq Star_eq Slash_eq Percent_eq 
%token L_brace R_brace
%token L_paren R_paren
%token ShiftL ShiftR ShiftL_eq ShiftR_eq
%token Less Less_eq Greater Greater_eq
%token Eq_eq Neq
%token Unary
%token LOr LAnd BOr BXor BAnd BNot LNot 
%token BAnd_eq Bor_eq BXor_eq
%token Minus_minus Plus_plus
%token QuestionMark Colon

(* Unary is a dummy terminal.
 * We need dummy terminals if we wish to assign a precedence
 * to a production that does not correspond to the precedence of
 * the rightmost terminal in that production.
 * Implicit in this is that precedence can only be inferred for
 * terminals. Therefore, don't try to assign precedence to "rules"
 * or "productions".
 *
 * Minus_minus is a dummy terminal to parse-fail on.
 *)
%right QuestionMark Colon
%left LOr
%left LAnd
%left BOr
%left BXor
%left BAnd
%left Eq_eq Neq
%left Less Less_eq Greater Greater_eq
%left ShiftL ShiftR
%left Plus Minus
%left Star Slash Percent
%right Unary

%nonassoc else_hack_1
%nonassoc Else

%start program

(* It's only necessary to provide the type of the start rule,
 * but it can improve the quality of parser type errors to annotate
 * the types of other rules.
 *)
%type <Ast.mstm list> program
%type <Ast.mstm list> stms
%type <Ast.stm> stm
%type <Ast.mstm> m(stm)
%type <Ast.decl> decl
%type <Ast.stm> simp
%type <Ast.exp> exp
%type <Ast.mexp> m(exp)
%type <Core.Int32.t> int_const
%type <Ast.binop> binop
%type <Ast.binop option> asnop

%%

program :
  | Int;
    Main;
    L_paren R_paren;
    b = block;
    Eof;
      { match b with Ast.Block p -> p | _ -> raise (Failure "block must be Block") }
  ;

(* This higher-order rule produces a marked result of whatever the
 * rule passed as argument will produce.
 *)
m(x) :
  | x = x;
      (* $startpos(s) and $endpos(s) are menhir's replacements for
       * Parsing.symbol_start_pos and Parsing.symbol_end_pos, but,
       * unfortunately, they can only be called from productions. *)
      { mark x $startpos(x) $endpos(x) }
  ;

type_ :
  | Int {Ast.Integer}
  | Bool {Ast.Bool}
  ;

stms :
  | (* empty *)
      { [] }
  | hd = m(stm); tl = stms;
      { hd :: tl }
  ;

stm :
  | s = simp; Semicolon;
      { s }
  | c = control;
      { c }
  | b = block;
      { b }

block : 
  | L_brace; body = stms; R_brace;
  {Ast.Block body }

decl :
  | tp = type_; ident = Ident;
      { Ast.New_var (ident, tp) }
  | tp = type_; ident = Ident; Assign; e = m(exp);
      { Ast.Init (ident, tp, e) }
  | tp = type_; Main;
      { Ast.New_var (Symbol.symbol "main", tp) }
  | tp = type_; Main; Assign; e = m(exp);
      { Ast.Init (Symbol.symbol "main", tp, e) }
  ;

simp :
  | lhs = m(exp);
    op = asnop;
    rhs = m(exp);
      { Ast.Assign (lhs, rhs, op) }
  | lhs = m(exp);
    op = postop;
    { Ast.PostOp (lhs, op) }
  | d = decl;
      { Ast.Declare d }
  | e = m(exp);
        { Ast.Exp e }
  ;

simpopt :
  | (* empty *)
    { None }
  | s = m(simp)
    { Some s }

exp :
  | L_paren; e = exp; R_paren;
      { e }
  | c = int_const;
      { Ast.Const c }
  | True; { Ast.True }
  | False; { Ast.False }
  | Main;
      { Ast.Var (Symbol.symbol "main") }
  | ident = Ident;
      { Ast.Var ident }
  | u = unop; { u }
  | lhs = m(exp);
    op = binop;
    rhs = m(exp);
      { Ast.Binop { op; lhs; rhs; } }
  | cond = m(exp); 
    QuestionMark; 
    f = m(exp);
    Colon; 
    s = m(exp); 
      { Ast.Ternary {cond = cond; first=f; second = s} }
  ;


unop : 
  | Minus; e = m(exp); %prec Unary
      { Ast.Unop { op = Ast.Negative; operand = e; } }
  | LNot; e = m(exp); %prec Unary
      { Ast.Unop { op = Ast.L_not ; operand = e; } }
  | BNot; e = m(exp); %prec Unary
      { Ast.Unop { op = Ast.B_not; operand = e; } }

int_const :
  | c = Dec_const;
      { c }
  | c = Hex_const;
      { c }
  ;


ifstm : 
    | If; 
    L_paren; 
    e = m(exp);
    R_paren;
    t = m(stm);
    Else; 
    f = m(stm);
      { Ast.If {cond = e; thenstm = t; elsestm = Some f } }
  | If; 
    L_paren; 
    e = m(exp);
    R_paren;
    t = m(stm);
    %prec else_hack_1
      { Ast.If {cond = e; thenstm = t; elsestm = None } }

control : 
    | i = ifstm;
      { i }
    | While;
      L_paren; 
      e = m(exp);
      R_paren;
      body = m(stm);
        {Ast.While {cond = e; body = body}}
    | For ;
      L_paren;
      init = simpopt;
      Semicolon;
      cond = m(exp);
      Semicolon;
      post = simpopt;
      R_paren;
      body = m(stm);
        { Ast.For { init = init; cond = cond; post = post; body = body}  }
    | Return; 
      e = m(exp);
      Semicolon;
        {Ast.Return e}


(* See the menhir documentation for %inline.
 * This allows us to factor out binary operators while still
 * having the correct precedence for binary operator expressions.
 *)
%inline
binop :
  | Plus;
      { Ast.Plus }
  | Minus;
      { Ast.Minus }
  | Star;
      { Ast.Times }
  | Slash;
      { Ast.Divided_by }
  | Percent;
      { Ast.Modulo }
  | Less;
      { Ast.Less}
  | Less_eq;
      { Ast.Less_eq}
  | Greater;
      { Ast.Greater}
  | Greater_eq;
      { Ast.Greater_eq}
  | Eq_eq;
      { Ast.Equals}
  | Neq;
      { Ast.Not_equals}
  | LAnd;
      { Ast.L_and}
  | LOr;
      { Ast.L_or}
  | BAnd;
      { Ast.B_and}
  | BOr;
      { Ast.B_or}
  | BXor;
      { Ast.B_xor}
  | ShiftL;
      { Ast.ShiftL}
  | ShiftR;
      { Ast.ShiftR}
  ;

asnop :
  | Assign
      { None }
  | Plus_eq
      { Some Ast.Plus }
  | Minus_eq
      { Some Ast.Minus }
  | Star_eq
      { Some Ast.Times }
  | Slash_eq
      { Some Ast.Divided_by }
  | Percent_eq
      { Some Ast.Modulo }
  | ShiftL_eq
      { Some Ast.ShiftL }
  | ShiftR_eq
      { Some Ast.ShiftR }
  | BAnd_eq
      { Some Ast.B_and }
  | Bor_eq
      { Some Ast.B_or }
  | BXor_eq
      { Some Ast.B_xor }
  ;


postop : 
  | Plus_plus 
      { Ast.Plus }
  | Minus_minus 
      { Ast.Minus }
  ;
%%