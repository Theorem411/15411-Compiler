open Core
module SSA = Ssa
module AS = Assem_l4
module Live = Live_faster
module LM = Live.LM
module LS = Live.LS
module TS = Temp.Set
module TT = Hashtbl.Make (Temp)
module ST = Hashtbl.Make (String)
module HeaderAst = Ast

let print_off = true
let preproc_instr_off = false

type temp_type =
  | Bool
  | Int
  | Pointer [@deriving equal]

let counter_reg : int ref = ref 0

let get_new_counter () =
  let x = !counter_reg in
  counter_reg := x + 1;
  x
;;

let equal_temp_typ a b =
  match a, b with
  | Bool, Bool -> true
  | Int, Int -> true
  | Pointer, Pointer -> true
  | _ -> false
;;

let temps_type_ref : temp_type TT.t ref = ref (TT.create ())
let get_temps_tbl () = !temps_type_ref
let todo_ref : TS.t ref = ref TS.empty
let get_todo_set () = !todo_ref
let set_todo_set s = todo_ref := s
let add_todo (t : Temp.t) = set_todo_set (TS.add (get_todo_set ()) t)
let is_empty_todo () = TS.is_empty !todo_ref
let remove_todo (t : Temp.t) = set_todo_set (TS.remove (get_todo_set ()) t)
let functions_list_ref : (string * AS.operand list * AS.operand option) list ref = ref []
let set_funs l = functions_list_ref := l

let remove_fun (s : string) =
  set_funs (List.filter ~f:(fun (f, _, _) -> not (String.equal s f)) !functions_list_ref)
;;

let add_fun f =
  if List.mem !functions_list_ref f ~equal:(fun (a, _, _) (b, _, _) -> String.equal a b)
  then ()
  else set_funs (f :: !functions_list_ref)
;;

(* let edit_ret (s : string) (ret_opt : AS.operand option) =
  let name, args, _ =
    List.find_exn !functions_list_ref ~f:(fun (fname, _, _) -> String.equal s fname)
  in
  let new_f = name, args, ret_opt in
  add_fun new_f
;; *)

(* let reset_temp () =
  todo_ref := TS.empty;
  temps_type_ref := TT.create ()
;; *)

let print_todo_set () =
  let s = get_todo_set () in
  let r =
    sprintf "{%s}" (String.concat ~sep:", " (List.map (TS.to_list s) ~f:Temp.name))
  in
  if print_off then () else prerr_endline r
;;

let pp_typ = function
  | Bool -> "B"
  | Int -> "I"
  | Pointer -> "P"
;;

let print_types () =
  let tbl = get_temps_tbl () in
  let kv = TT.to_alist tbl in
  let r =
    sprintf
      "[%s]"
      (String.concat
         ~sep:", "
         (List.map kv ~f:(fun (t, typ) -> sprintf "%s:%s" (Temp.name t) (pp_typ typ))))
  in
  if print_off then () else prerr_endline r
;;

let set_type (t : Temp.t) typ =
  if print_off
  then ()
  else prerr_endline (sprintf "adding %s -> %s" (Temp.name t) (pp_typ typ));
  let tbl = get_temps_tbl () in
  remove_todo t;
  match TT.find tbl t with
  | None -> TT.add_exn tbl ~key:t ~data:typ
  | Some old ->
    if equal_temp_typ typ old then () else failwith ("not equal type for" ^ Temp.name t)
;;

let get_type (t : Temp.t) =
  let tbl = get_temps_tbl () in
  TT.find tbl t
;;

let pp_get_size_temp t =
  match get_type t with
  | Some Bool -> "i32"
  | Some Int -> "i32"
  | Some Pointer -> "ptr"
  | None ->
    if not print_off then prerr_endline (Temp.name t ^ " defaulted to i32");
    "i32"
;;

let str_to_typ = function
  | "i1" -> Bool
  | "i32" -> Int
  | "ptr" -> Pointer
  | s -> failwith ("str_to_typ got " ^ s)
;;

let set_type_if_temp (typ : temp_type) (o : AS.operand) =
  match o with
  | Temp t -> set_type t typ
  | _ -> ()
;;

let not_zero_one n =
  if Int64.equal n Int64.one then false else not (Int64.equal n Int64.zero)
;;

let if_any_typ (o : AS.operand) =
  match o with
  | AS.Temp t -> get_type t
  | AS.Reg _ -> None
  | AS.Imm n -> if not_zero_one n then Some Int else None
;;

let pp_get_size_op_opt o =
  match o with
  | AS.Temp t ->
    (match get_type t with
    | Some Bool -> Some "i32"
    | Some Int -> Some "i32"
    | Some Pointer -> Some "ptr"
    | None -> None)
  | AS.Imm n -> if not_zero_one n then Some "i32" else None
  | _ -> None
;;

let get_op_type o =
  match pp_get_size_op_opt o with
  | Some x -> x
  | None -> "i32"
;;

let debug_pp_ret = function
  | None -> "void"
  | Some op -> get_op_type op
;;

let print_args_types args = List.map args ~f:get_op_type

let print_fun_list_debug () =
  let s = !functions_list_ref in
  let r =
    let print_f (name, args, ret_opt) =
      sprintf
        "%s %s(%s)"
        (debug_pp_ret ret_opt)
        name
        (String.concat ~sep:", " (print_args_types args))
    in
    String.concat ~sep:";\n" (List.map s ~f:print_f)
  in
  if print_off then () else prerr_endline ("[" ^ r ^ "]")
;;

let glob_goodblock_set = ref LS.empty
let add_to_goodblock l = glob_goodblock_set := LS.add !glob_goodblock_set l
let is_goodblock l = Option.is_some (LS.find ~f:(Label.equal_bt l) !glob_goodblock_set)

type program = SSA.program

let create p = p
let pp_reg r = "%" ^ AS.format_reg r

let pp_operand ?(size = AS.S) op =
  match op, size with
  | AS.Imm n, AS.L ->
    if AS.equal_operand (AS.Imm Int64.zero) op then "null" else Int64.to_string n
  | AS.Imm n, _ -> Int64.to_string n
  | AS.Temp t, _ -> Temp.name t
  | AS.Reg r, _ -> pp_reg r
;;

let pp_pure_operation = function
  | AS.Add -> "add"
  | AS.Sub -> "sub"
  | AS.Mul -> "mul"
  | AS.BitAnd -> "and"
  | AS.BitXor -> "xor"
  | AS.BitOr -> "or"
;;

let pp_size = function
  | AS.L -> "ptr"
  | AS.S -> "i32"
;;

let fun_ret_size_ref : AS.size option ST.t ref = ref (ST.create ())

let get_size_str_opt_fun (s : string) =
  let size_opt_opt = ST.find !fun_ret_size_ref s in
  match size_opt_opt with
  | None -> None
  | Some None -> Some "void"
  | Some (Some x) -> Some (pp_size x)
;;

let add_fun_ret (s : Symbol.t) r =
  let name = Symbol.name s in
  match r, ST.find !fun_ret_size_ref name with
  | _, None -> ST.add_exn ~key:name ~data:r !fun_ret_size_ref
  | Some sz, Some None -> ST.update !fun_ret_size_ref name ~f:(fun _ -> Some sz)
  | None, Some None -> ()
  | _ -> ()
;;

let pp_set_typ = function
  | AS.Sete -> "eq"
  | AS.Setne -> "ne"
  | AS.Setg -> "sgt"
  | AS.Setge -> "sge"
  | AS.Setl -> "slt"
  | AS.Setle -> "sle"
;;

(* let pp_get_cmp_size (size, lhs, rhs) =
  match lhs, rhs with
  | AS.Temp _, _ -> pp_get_size_op_exn lhs
  | _, AS.Temp _ -> pp_get_size_op_exn rhs
  | _, _ -> pp_size size
;; *)

let pp_label (l : Label.t) = "%L" ^ Int.to_string (Label.number l)
let pp_label_raw (l : Label.t) = "L" ^ Int.to_string (Label.number l)

let rec pp_instr (instr : AS.instr) : string = "\t" ^ pp_instr' instr

and pp_bt (l : Label.bt) =
  match l with
  | FunName _ -> "%entry"
  | BlockLbl l -> pp_label l

and pp_xor = function
  | AS.PureBinop ({ op = AS.BitXor; size; rhs = AS.Imm n; _ } as binop) ->
    if Int64.equal Int64.one n
    then (
      let lhs_final =
        match binop.lhs with
        | AS.Temp _ -> sprintf "%s_i" (pp_operand binop.lhs)
        | _ -> pp_operand binop.lhs
      in
      sprintf
        "%s = %s %s %s, %s\n\t%s_i = %s i1 %s, %s"
        (pp_operand binop.dest)
        (pp_pure_operation binop.op)
        (pp_size size)
        (pp_operand binop.lhs)
        (pp_operand binop.rhs)
        (pp_operand binop.dest)
        (pp_pure_operation binop.op)
        lhs_final
        (pp_operand binop.rhs))
    else
      sprintf
        "%s = %s %s %s, %s"
        (pp_operand binop.dest)
        (pp_pure_operation binop.op)
        (pp_size size)
        (pp_operand binop.lhs)
        (pp_operand binop.rhs)
  | _ -> failwith "pp+xor got not imm xor"

and pp_add_offset = function
  | AS.PureBinop { op = AS.Add; size = AS.L; lhs; rhs = AS.Temp _ as rhs; dest } ->
    let n = get_new_counter () in
    sprintf
      "%s_int_rhs%d = ptrtoint ptr %s to i64\n\
       \t%s_int_pbadd_rhs%d = ptrtoint ptr %s to i64\n\
       \t%s_int_pbadd_added_rhs%d = add nsw i64 %s_int_pbadd_rhs%d, %s_int_rhs%d\n\
       \t%s = inttoptr i64 %s_int_pbadd_added_rhs%d to ptr"
      (pp_operand rhs)
      n
      (pp_operand rhs)
      (pp_operand lhs)
      n
      (pp_operand lhs)
      (pp_operand lhs)
      n
      (pp_operand lhs)
      n
      (pp_operand rhs)
      n
      (pp_operand dest)
      (pp_operand lhs)
      n
  | AS.PureBinop { op = AS.Sub; size = AS.L; lhs; rhs = AS.Imm _ as rhs; dest } ->
    let n = get_new_counter () in
    sprintf
      "%s_int_pbadd%d = ptrtoint ptr %s to i64\n\
       \t%s_int_pbadd_added%d = sub nsw i64 %s_int_pbadd%d, %s\n\
       \t%s = inttoptr i64 %s_int_pbadd_added%d to ptr"
      (pp_operand lhs)
      n
      (pp_operand lhs)
      (pp_operand lhs)
      n
      (pp_operand lhs)
      n
      (pp_operand rhs)
      (pp_operand dest)
      (pp_operand lhs)
      n
  | AS.PureBinop
      { op = AS.Add; size = AS.L; lhs = AS.Imm _ as lhs; rhs = AS.Imm _ as rhs; dest } ->
    let n = get_new_counter () in
    sprintf
      "%%t%s_int%d = ptrtoint ptr %s to i64\n\
       \t%%t%s_int_pbadd_added%d = add nsw i64 %%t%s_int%d, %s\n\
       \t%s = inttoptr i64 %%t%s_int_pbadd_added%d to ptr"
      (pp_operand lhs)
      n
      (pp_operand lhs ~size:AS.L)
      (pp_operand lhs)
      n
      (pp_operand lhs)
      n
      (pp_operand rhs)
      (pp_operand dest)
      (pp_operand lhs)
      n
  | AS.PureBinop { op = AS.Add; size = AS.L; lhs; rhs = AS.Imm _ as rhs; dest } ->
    let n = get_new_counter () in
    sprintf
      "%s_int%d = ptrtoint ptr %s to i64\n\
       \t%s_int_pbadd_added%d = add nsw i64 %s_int%d, %s\n\
       \t%s = inttoptr i64 %s_int_pbadd_added%d to ptr"
      (pp_operand lhs)
      n
      (pp_operand lhs)
      (pp_operand lhs)
      n
      (pp_operand lhs)
      n
      (pp_operand rhs)
      (pp_operand dest)
      (pp_operand lhs)
      n
  | AS.PureBinop { op = AS.Mul; size = AS.L; lhs; rhs = AS.Imm m; dest } ->
    let n = get_new_counter () in
    sprintf
      "%s_int%d = ptrtoint ptr %s to i64\n\
       \t%s_intmulted%d = mul i64 %s_int%d, %d\n\
       \t%s = inttoptr i64 %s_intmulted%d to ptr"
      (pp_operand lhs)
      n
      (pp_operand lhs)
      (pp_operand lhs)
      n
      (pp_operand lhs)
      n
      (Int64.to_int_exn m)
      (pp_operand dest)
      (pp_operand lhs)
      n
  | __instr -> failwith ("pp_add_offset recieved weird input: " ^ AS.format_instr __instr)

and pp_instr' : AS.instr -> string = function
  | PureBinop { op = AS.BitXor; rhs = AS.Imm _; _ } as instr -> pp_xor instr
  | PureBinop { op = AS.Add | AS.Sub | AS.Mul; size = AS.L; _ } as instr ->
    pp_add_offset instr
  | PureBinop ({ op = AS.BitAnd | AS.BitOr | AS.BitXor; size; _ } as binop) ->
    sprintf
      "%s = %s %s %s, %s"
      (pp_operand binop.dest)
      (pp_pure_operation binop.op)
      (pp_size size)
      (pp_operand binop.lhs)
      (pp_operand binop.rhs)
  | PureBinop binop ->
    sprintf
      "%s = %s nsw %s %s, %s"
      (pp_operand binop.dest)
      (pp_pure_operation binop.op)
      (pp_size binop.size)
      (pp_operand binop.lhs)
      (pp_operand binop.rhs)
  | EfktBinop { op; dest; lhs; rhs } ->
    sprintf
      "%s = call i32 @%s(i32 %s, i32 %s)"
      (pp_operand dest)
      (Custom_functions.get_efkt_name op)
      (pp_operand lhs)
      (pp_operand rhs)
  | Unop { dest = AS.Temp _ as dest; src; _ } ->
    sprintf "%s = xor i32 %s, -1" (pp_operand dest) (pp_operand src)
  | Unop _ -> failwith "got unop with dest != temp"
  | Mov { dest = AS.Reg _ as dest; src; size } ->
    sprintf "; %s <-%s- %s" (pp_operand dest) (pp_size size) (pp_operand src)
  | Mov { src = AS.Reg _ as src; dest; size } ->
    sprintf "; %s <-%s- %s" (pp_operand dest) (pp_size size) (pp_operand src)
  | Mov { dest; src; size } ->
    sprintf "%s <-%s- %s" (pp_operand dest) (pp_size size) (pp_operand src)
  | MovSxd { dest; src } ->
    sprintf "%s = inttoptr i32 %s to ptr" (pp_operand dest) (pp_operand src)
  | Directive dir -> sprintf "%s" dir
  | Comment comment -> sprintf "/* %s */" comment
  | Jmp l -> "; jump " ^ pp_label l
  | Cjmp c ->
    sprintf "; %s %s" (c.typ |> AS.sexp_of_jump_t |> string_of_sexp) (pp_label c.l)
  | Lab l -> ".Label " ^ pp_label l
  | Ret -> "; ret %EAX"
  | Set c ->
    sprintf "; %s %s" (c.typ |> AS.sexp_of_set_t |> string_of_sexp) (pp_operand c.src)
  | Cmp { size = AS.L as size; lhs; rhs } ->
    sprintf "; cmp%s %s, %s" (pp_size size) (pp_operand lhs ~size) (pp_operand rhs ~size)
  | Cmp { size; lhs; rhs } ->
    sprintf "; cmp%s %s, %s" (pp_size size) (pp_operand lhs) (pp_operand rhs)
  | AssertFail -> "call void @raise(i32 6) ;"
  | Call { fname; args_in_regs; args_overflow; tail_call } ->
    sprintf
      ";call %s(%s|%s)[tail call - %b]"
      (Symbol.name fname)
      (List.map args_in_regs ~f:(fun (r, s) -> sprintf "%s%s" (pp_reg r) (pp_size s))
      |> String.concat ~sep:", ")
      (List.map args_overflow ~f:(fun (op, s) ->
           sprintf "%s%s" (pp_operand op) (pp_size s))
      |> String.concat ~sep:", ")
      tail_call
  | LoadFromStack ts ->
    sprintf
      "loadfromstack {%s}"
      (List.map ts ~f:(fun (t, s) -> sprintf "%s%s" (Temp.name t) (pp_size s))
      |> String.concat ~sep:", ")
  | MovFrom { dest; size; src } ->
    sprintf "; %s <-%s- (%s)" (pp_operand dest) (pp_size size) (pp_operand src)
  | MovTo { dest; size; src } ->
    sprintf "; (%s) <-%s- %s" (pp_operand dest) (pp_size size) (pp_operand src)
  | LeaPointer { dest; base; offset; size } ->
    sprintf
      "%s <- lea: [%s] %s + %d"
      (pp_operand dest)
      (pp_size size)
      (pp_operand base)
      offset
  | LeaArray { dest; base; offset; index; scale } ->
    sprintf
      "%s <- lea: %s + %s * %d + %d"
      (pp_operand dest)
      (pp_operand base)
      (pp_operand index)
      scale
      offset
  | LLVM_Jmp l -> sprintf "br label %s" (pp_label l)
  | LLVM_Cmp { dest; lhs; rhs; typ; size = AS.L as size } (*next line*)
  | LLVM_Set { dest; lhs; rhs; typ; size = AS.L as size } ->
    sprintf
      "%s_i = icmp %s %s %s, %s\n\t%s = zext i1 %s_i to i32\n"
      (pp_operand dest)
      (pp_set_typ typ)
      (pp_size size)
      (pp_operand lhs ~size)
      (pp_operand rhs ~size)
      (* first line end *)
      (pp_operand dest)
      (pp_operand dest)
  | LLVM_Cmp { dest; lhs; rhs; typ; size } (*next line*)
  | LLVM_Set { dest; lhs; rhs; typ; size } ->
    sprintf
      "%s_i = icmp %s %s %s, %s\n\t%s = zext i1 %s_i to %s"
      (pp_operand dest)
      (pp_set_typ typ)
      (pp_size size)
      (pp_operand lhs ~size)
      (pp_operand rhs ~size)
      (pp_operand dest)
      (pp_operand dest)
      (pp_size size)
  | LLVM_IF { cond; tl; fl } ->
    sprintf "br i1 %s_i, label %s, label %s" (pp_operand cond) (pp_label tl) (pp_label fl)
  | LLVM_Ret None -> "ret void"
  | LLVM_Ret (Some (src, sz)) ->
    sprintf "ret %s %s" (pp_size sz) (pp_operand src ~size:sz)
  | LLVM_Call { dest = Some (dest, sz); args; fname } ->
    sprintf
      "%s = call %s @%s(%s)"
      (pp_operand dest)
      (pp_size sz)
      (Symbol.name fname)
      (List.map args ~f:(fun (op, s) ->
           sprintf "%s %s" (pp_size s) (pp_operand op ~size:s))
      |> String.concat ~sep:", ")
  | LLVM_Call { dest = None; args; fname } ->
    sprintf
      "call %s @%s(%s)"
      (Option.value (get_size_str_opt_fun (Symbol.name fname)) ~default:"void")
      (Symbol.name fname)
      (List.map args ~f:(fun (op, s) ->
           sprintf "%s %s" (pp_size s) (pp_operand op ~size:s))
      |> String.concat ~sep:", ")
  | LLVM_NullCheck { dest; _ } ->
    sprintf
      "call void @%s(%s %s)"
      (Custom_functions.get_efkt_name_ops "check_null")
      (pp_size AS.L)
      (pp_operand dest ~size:AS.L)
  | LLVM_ArrayIdxCheck { index; length } ->
    sprintf
      "call void @%s(i32 %s, i32 %s)"
      (Custom_functions.get_efkt_name_ops "check_array")
      (pp_operand index)
      (pp_operand length)
  | LLVM_MovTo { dest = AS.Imm n; size; src } ->
    let m = get_new_counter () in
    sprintf
      "%%t%d_intptrmoveto%d = inttoptr i32 %d to ptr\n\
       \tstore %s %s, %s %%t%d_intptrmoveto%d"
      (Int64.to_int_exn n)
      m
      (Int64.to_int_exn n)
      (* second line done *)
      (pp_size size)
      (pp_operand src ~size)
      (pp_size AS.L)
      (Int64.to_int_exn n)
      m
  | LLVM_MovTo { dest; size; src } ->
    sprintf
      "store %s %s, %s %s"
      (pp_size size)
      (pp_operand src ~size)
      (pp_size AS.L)
      (pp_operand dest ~size:AS.L)
  | LLVM_MovFrom { dest; size; src = AS.Imm n } ->
    let m = get_new_counter () in
    sprintf
      "%s_intptr%d = inttoptr i32 %d to ptr\n\t%s = load %s, %s %s_intptr%d"
      (pp_operand dest)
      m
      (Int64.to_int_exn n)
      (* first line done *)
      (pp_operand dest)
      (pp_size size)
      (pp_size AS.L)
      (pp_operand dest)
      m
  | LLVM_MovFrom { dest; size; src } ->
    sprintf
      "%s = load %s, %s %s"
      (pp_operand dest)
      (pp_size size)
      (pp_size AS.L)
      (pp_operand src ~size:AS.L)
;;

let pp_phi ({ self; alt_selves } : SSA.phi) : string =
  (* TODO *)
  let phi_size = pp_get_size_temp self in
  let from_alt_selves_opt =
    List.find_map ~f:(fun (_, op) -> pp_get_size_op_opt op) alt_selves
  in
  let phi_size =
    match from_alt_selves_opt with
    | None -> phi_size
    | Some x ->
      set_type self (str_to_typ x);
      x
  in
  let format_oprnd' op =
    match phi_size with
    | "ptr" -> if AS.equal_operand (AS.Imm Int64.zero) op then "null" else pp_operand op
    | _ -> pp_operand op
  in
  sprintf
    "\t%s = phi %s %s"
    (* "\t%s = phi (phi_size) %s" *)
    (Temp.name self)
    phi_size
    (List.filter_map alt_selves ~f:(fun (l, op) ->
         if not (is_goodblock l)
         then None
         else Some (sprintf "[%s, %s]" (format_oprnd' op) (pp_bt l)))
    |> String.concat ~sep:", ")
;;

let pp_instr (_ : int) (instr : SSA.instr) : string =
  match instr with
  | SSA.ASInstr instr -> pp_instr instr
  | SSA.Phi phi -> pp_phi phi
  | SSA.Nop -> ""
;;

let pp_parents ~(cfg_pred : LS.t LM.t) (l : Label.bt) =
  let parent_set = LM.find_exn cfg_pred l in
  sprintf
    "; preds = %s"
    (String.concat
       ~sep:", "
       (List.filter_map (LS.to_list parent_set) ~f:(fun l ->
            if not (is_goodblock l) then None else Some (pp_bt l))))
;;

let pp_block
    ?(drop_before = None)
    ~(cfg_pred : LS.t LM.t)
    ({ label; lines; _ } : SSA.block)
    (code : SSA.instr SSA.IH.t)
    : string
  =
  let l2code =
    List.filter_map lines ~f:(fun l ->
        (* drop everything before and load from stack (including) *)
        if l <= Option.value ~default:(-1) drop_before
        then None
        else (
          let instr = SSA.IH.find_exn code l in
          match instr with
          | Nop -> None
          | _ -> Some (pp_instr l instr)))
  in
  let pp_parent_blocks = pp_parents ~cfg_pred in
  match label with
  | Label.BlockLbl l ->
    if is_goodblock label
    then
      sprintf
        "%s:\t\t\t\t\t\t\t\t\t\t\t\t%s\n%s\n"
        (pp_label_raw l)
        (pp_parent_blocks label)
        (String.concat l2code ~sep:"\n")
    else ""
  | Label.FunName _ -> sprintf "%s\n" (String.concat l2code ~sep:"\n")
;;

(* (AS.format_jump_tag jump) *)

let pp_args (args : (Temp.t * AS.size) list) : string =
  List.map args ~f:(fun (t, sz) -> sprintf "%s %s" (pp_size sz) (Temp.name t))
  |> String.concat ~sep:", "
;;

(* to be changed *)
let get_args ({ code; block_info; _ } : SSA.fspace) =
  let first_block = List.nth_exn block_info 0 in
  let load_from_stack_args, load_line =
    List.find_map_exn first_block.lines ~f:(fun l ->
        match SSA.IH.find_exn code l with
        | ASInstr (AS.LoadFromStack tmp_args) -> Some (tmp_args, l)
        | _ -> None)
  in
  let reg_move_lines =
    List.take_while first_block.lines ~f:(fun l ->
        match SSA.IH.find_exn code l with
        | ASInstr (AS.Mov _) -> true
        | _ -> false)
  in
  let reg_args =
    List.filter_map reg_move_lines ~f:(fun l ->
        match SSA.IH.find_exn code l with
        | ASInstr (AS.Mov { dest = AS.Temp t; size; _ }) -> Some (t, size)
        | _ -> failwith "not a reg move in reg_move_args")
  in
  Some load_line, reg_args @ load_from_stack_args
;;

(* let pp_entry_lbl fname = "entry_" ^ Symbol.name fname ^ ":" *)
let pp_entry_lbl _ = "entry:"

let add_to_todo l =
  let l =
    List.filter_map l ~f:(fun o ->
        match o with
        | AS.Temp t -> Some t
        | _ -> None)
  in
  List.iter l ~f:(fun t ->
      match get_type t with
      | None -> add_todo t
      | Some _ -> ())
;;

let preprocess_phi (s : SSA.instr) =
  match s with
  | Phi { self; alt_selves } ->
    let self_typ_opt = get_type self in
    let useful_parents =
      List.filter_map alt_selves ~f:(fun (p, o) ->
          if is_goodblock p then Some o else None)
    in
    let typ_opt = List.find_map useful_parents ~f:if_any_typ in
    (match typ_opt, self_typ_opt with
    | None, None -> add_to_todo (AS.Temp self :: useful_parents)
    | _, Some t | Some t, _ ->
      set_type self t;
      List.iter ~f:(set_type_if_temp t) useful_parents);
    ()
  | _ -> failwith "preprocess_phi got no phi"
;;

let preprocess_opsz (op, sz) =
  match sz with
  | AS.S -> ()
  | AS.L -> set_type_if_temp Pointer op
;;

let preprocess_call instr =
  match instr with
  | AS.LLVM_Call c ->
    let name = Symbol.name c.fname in
    let args =
      List.map
        ~f:(fun (op, sz) ->
          preprocess_opsz (op, sz);
          op)
        c.args
    in
    let ret_opt, sz =
      match c.dest with
      | None -> None, None
      | Some (op, sz) ->
        preprocess_opsz (op, sz);
        Some op, Some sz
    in
    add_fun (name, args, ret_opt);
    add_fun_ret c.fname sz
  | _ -> failwith ("preprocess_call is got " ^ AS.format_instr instr)
;;

let preprocess_block_instrs (code : SSA.instr SSA.IH.t) (block : SSA.block) : unit =
  if preproc_instr_off
  then ()
  else (
    List.iter block.lines ~f:(fun l ->
        let instr = SSA.IH.find_exn code l in
        match instr with
        | Nop -> ()
        | Phi _ -> preprocess_phi instr
        | ASInstr (PureBinop { size = AS.L; dest; _ }) -> set_type_if_temp Pointer dest
        | ASInstr (LLVM_Cmp { size = AS.L; lhs; rhs; _ }) ->
          List.iter [ lhs, AS.L; rhs, AS.L ] ~f:preprocess_opsz
        | ASInstr (LLVM_Set { size = AS.L; lhs; rhs; _ }) ->
          List.iter [ lhs, AS.L; rhs, AS.L ] ~f:preprocess_opsz
        | ASInstr (LLVM_MovTo { size; dest; src }) ->
          List.iter [ dest, AS.L; src, size ] ~f:preprocess_opsz
        | ASInstr (LLVM_MovFrom { size; src; dest }) ->
          List.iter [ src, AS.L; dest, size ] ~f:preprocess_opsz
        | ASInstr (LLVM_NullCheck { dest; _ }) -> set_type_if_temp Pointer dest
        | ASInstr (LLVM_Call _ as ins) -> preprocess_call ins
        | _ -> ());
    if print_off
    then ()
    else prerr_endline (sprintf "done with block %s" (Label.format_bt block.label));
    print_todo_set ();
    print_types ();
    print_fun_list_debug ())
;;

let preprocess_blocks (code : SSA.instr SSA.IH.t) (blocks : SSA.block list) : unit =
  let child_labels = function
    | AS.JRet -> []
    | AS.JCon { jt; jf } -> [ Label.BlockLbl jt; Label.BlockLbl jf ]
    | AS.JUncon l -> [ Label.BlockLbl l ]
  in
  let root = List.nth_exn blocks 0 in
  let block_map = LM.of_alist_exn (List.map blocks ~f:(fun b -> b.label, b)) in
  let rec dfs block_map (lbl : Label.bt) =
    if not (is_goodblock lbl)
    then (
      add_to_goodblock lbl;
      let b : SSA.block = LM.find_exn block_map lbl in
      preprocess_block_instrs code b;
      List.iter ~f:(dfs block_map) (child_labels b.jump))
  in
  dfs block_map root.label
;;

let preprocess_phi_block_instrs (code : SSA.instr SSA.IH.t) (block : SSA.block) : unit =
  let phi_nop_lines =
    List.take_while block.lines ~f:(fun l ->
        let instr = SSA.IH.find_exn code l in
        match instr with
        | Nop -> true
        | Phi _ -> true
        | _ -> false)
  in
  List.iter phi_nop_lines ~f:(fun l ->
      let instr = SSA.IH.find_exn code l in
      match instr with
      | Nop -> ()
      | Phi _ -> preprocess_phi instr
      | _ -> failwith "doing only phi, wtf");
  if print_off
  then ()
  else prerr_endline (sprintf "done with phi's of block %s" (Label.format_bt block.label));
  print_todo_set ();
  print_types ()
;;

let preprocess_blocks_phi (code : SSA.instr SSA.IH.t) (blocks : SSA.block list) : unit =
  if is_empty_todo ()
  then ()
  else (
    let child_labels = function
      | AS.JRet -> []
      | AS.JCon { jt; jf } -> [ Label.BlockLbl jt; Label.BlockLbl jf ]
      | AS.JUncon l -> [ Label.BlockLbl l ]
    in
    let root = List.nth_exn blocks 0 in
    let block_map = LM.of_alist_exn (List.map blocks ~f:(fun b -> b.label, b)) in
    let local_visited_set = ref LS.empty in
    let add_to_visited l = local_visited_set := LS.add !local_visited_set l in
    let is_visited l =
      Option.is_some (LS.find ~f:(Label.equal_bt l) !local_visited_set)
    in
    let rec dfs block_map (lbl : Label.bt) =
      if (not (is_visited lbl)) && not (is_empty_todo ())
      then (
        add_to_visited lbl;
        let b : SSA.block = LM.find_exn block_map lbl in
        preprocess_phi_block_instrs code b;
        List.iter ~f:(dfs block_map) (child_labels b.jump))
    in
    dfs block_map root.label)
;;

let pp_fspace ({ fname; code; block_info; cfg_pred; ret_size; _ } as fspace : SSA.fspace)
    : string
  =
  let drop_before, args = get_args fspace in
  let res =
    sprintf
      "; Function Attrs: norecurse nounwind readnone\n\
       define dso_local %s @%s(%s) #0 {\n\
       %s\n\
       }\n"
      (Option.map ~f:pp_size ret_size |> Option.value ~default:"void")
      (Symbol.name fname)
      (pp_args args)
      (match block_info with
      | first_block :: rest ->
        pp_entry_lbl fname
        :: pp_block ~drop_before ~cfg_pred first_block code
        :: List.map rest ~f:(fun b -> pp_block ~cfg_pred b code)
        |> String.concat ~sep:"\n"
      | _ -> failwith "fspace can not be empty")
  in
  (* reset_temp (); *)
  res
;;

let pp_program_helper (prog : program) : string =
  List.map prog ~f:pp_fspace |> String.concat ~sep:"\n"
;;

let custom_funs =
  [ Custom_functions.get_efkt_name_ops "alloc"
  ; Custom_functions.get_efkt_name_ops "alloc_array"
  ]
;;

let pp_declare () =
  let s = !functions_list_ref in
  (* ignore custom functions *)
  let s =
    List.filter s ~f:(fun (a, _, _) -> not (List.mem ~equal:String.equal custom_funs a))
  in
  let r =
    let print_f (name, args, ret_opt) =
      sprintf
        "declare dso_local %s @%s(%s) #1"
        (debug_pp_ret ret_opt)
        name
        (String.concat ~sep:", " (print_args_types args))
    in
    String.concat ~sep:";\n" (List.map s ~f:print_f)
  in
  r
;;

let preprocess_prog ({ block_info; fname; ret_size; code; _ } as fspace : SSA.fspace) =
  add_fun_ret fname ret_size;
  preprocess_blocks code block_info;
  let _, real_args = get_args fspace in
  List.iter real_args ~f:(fun (t, sz) -> preprocess_opsz (AS.Temp t, sz));
  List.iter
    ~f:(fun i ->
      if not print_off then prerr_endline (sprintf "%d's loop" i);
      preprocess_blocks_phi code block_info)
    [ 0; 1; 2 ]
;;

let pp_program (prog : program) : string =
  List.iter prog ~f:preprocess_prog;
  let prog_string = pp_program_helper prog in
  (* remove fun from the list of the functions that have to be declared, as this is a defintion *)
  List.iter prog ~f:(fun { fname; _ } -> remove_fun (Symbol.name fname));
  let declare_string = pp_declare () in
  String.concat
    ~sep:"\n"
    [ "; DECLARING FUNCTIONS"; declare_string; "; BODY "; prog_string ]
;;

let get_pre = Custom_functions.get_pre
let get_post = Custom_functions.get_post