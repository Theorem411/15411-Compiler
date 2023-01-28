(* L1 Compiler
 * Assembly language
 * Author: Kaustuv Chaudhuri <kaustuv+@andrew.cmu.edu>
 * Modified By: Alex Vaynberg <alv@andrew.cmu.edu>
 * Modified: Frank Pfenning <fp@cs.cmu.edu>
 * Converted to OCaml by Michael Duggan <md5i@cs.cmu.edu>
 *
 * Currently just a pseudo language with 3-operand
 * instructions and arbitrarily many temps
 *
 *)

 open Core

 type reg = EAX
 [@@deriving equal]
 
 type operand2D =
   | Imm of Int32.t
   | Reg of reg
   | Temp of Temp.t
   [@@deriving equal]
 
 type operation2D =
   | Add
   | Sub
   | Mul
   | Div
   | Mod
   | Mov
 
 type instr2D =
   | Command of
       { op : operation2D
       ; dest : operand2D
       ; src : operand2D
       }
   | Directive of string
   | Comment of string
 
 val format : instr2D -> string
 