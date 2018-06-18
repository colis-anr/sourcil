(******************************************************************************)
(*                                                                            *)
(*                                  SourCIL                                   *)
(*              Utilities around the CoLiS Intermediate Language              *)
(*                                                                            *)
(*   Copyright (C) 2018  Yann Régis-Gianas, Ralf Treinen, Nicolas Jeannerod   *)
(*                                                                            *)
(*   This program is free software: you can redistribute it and/or modify     *)
(*   it under the terms of the GNU General Public License as published by     *)
(*   the Free Software Foundation, either version 3 of the License, or        *)
(*   (at your option) any later version.                                      *)
(*                                                                            *)
(*   This program is distributed in the hope that it will be useful,          *)
(*   but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(*   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(*   GNU General Public License for more details.                             *)
(*                                                                            *)
(*   You should have received a copy of the GNU General Public License        *)
(*   along with this program.  If not, see <http://www.gnu.org/licenses/>.    *)
(*                                                                            *)
(******************************************************************************)

open Morsmall.AST
open Errors

let special_builtins = [
    "break"; ":"; "continue"; "."; "eval"; "exec";
    "exit"; "export"; "readonly"; "return"; "set";
    "shift"; "times"; "trap"; "unset" ]
(* cd is not in that list because it is technically not a special built-in! *)

let rec word__to__name = function
  | [Name l] -> l (* FIXME: we probably want to exclude characters here *)
  | [Literal l] -> l (* ? *)
  | [DoubleQuoted _] -> raise (NotSupported "double quotes in name")
  | [Variable _] -> raise (NotSupported "variable in name")
  | [Subshell _] -> raise (NotSupported "subshell in name")
  | [Assignment _] -> raise (NotSupported "assignment in name")
  | [GlobAll] -> raise (NotSupported "glob * in name")
  | [GlobAny] -> raise (NotSupported "glob ? in name")
  | [GlobRange _] -> raise (NotSupported "glob range in name")
  | [] -> raise (NotSupported "empty name")
  | _ :: _ :: _ -> raise (NotSupported "name >=2")

and word__to__literal = function
  | [Literal l] -> l
  | _ -> raise (NotSupported "literal other than literal")

and word_component_double_quoted__to__expression_component = function
  | Name n -> AST.ELiteral n
  | Literal l -> AST.ELiteral l
  | Variable v -> AST.EVariable (false, v)
  | Subshell c -> AST.ESubshell (false, command_list__to__statement c)

  | DoubleQuoted _ -> assert false
  | GlobAll -> assert false
  | GlobAny -> assert false
  | GlobRange _ -> assert false
  | Assignment _ -> assert false

and word_double_quoted__to__expression word =
  List.map word_component_double_quoted__to__expression_component word

and word_component__to__expression = function
  | Name n ->
     [AST.ELiteral n]
  | Literal l ->
     [AST.ELiteral l]
  | Variable v ->
     [AST.EVariable (true, v)]
  | DoubleQuoted w ->
     word_double_quoted__to__expression w
  | Subshell c ->
     [AST.ESubshell (true, command_list__to__statement c)]

  | Assignment _ -> raise (NotSupported "assignment")
  | GlobAll -> raise (NotSupported "glob *")
  | GlobAny -> raise (NotSupported "glob ?")
  | GlobRange _ -> raise (NotSupported "char range")

and word__to__expression word =
  List.map word_component__to__expression word
  |> List.flatten

and word__to__pattern_component = function
  | [Name l] | [Literal l] -> AST.PLiteral l
  | [] -> raise (NotSupported "empty pattern")
  | _ :: _ :: _ -> raise (NotSupported "pattern of size >= 2")
  | [GlobAll] -> raise (NotSupported "pattern globall")
  | [GlobAny] -> raise (NotSupported "pattern globany")
  | [Variable _] -> raise (NotSupported "pattern variable")
  | [Assignment _] -> raise (NotSupported "pattern assignment")
  | _ -> raise (NotSupported "other patterns")

and pattern__to__pattern pattern =
  List.map word__to__pattern_component pattern

and assignment__to__assign assignment =
  AST.Assign (assignment.variable, word__to__expression assignment.word)

(* Morsmall.AST.command -> Sourcil.AST.statement *)

and command__to__statement = function

  | Simple ([], []) ->
     assert false

  | Simple (assignment :: assignments, []) ->
     List.fold_left
       (fun statement assignment ->
         let assign = assignment__to__assign assignment in
         AST.Seq (statement, assign))
       (assignment__to__assign assignment)
       assignments

  | Simple (assignments, word :: words) ->
     let name = word__to__name word in
     let args = List.map word__to__expression words in
     if name = "eval" then
       raise (NotSupported "eval")
     else if List.mem name special_builtins then
       (
         assert (assignments = []);
         AST.CallSpecial (name, args)
       )
         (* FIXME: functions and cd *)
     else
       (
         let command =
           List.fold_right
             (fun assignment statement ->
               let assign = assignment__to__assign assignment in
               (* FIXME: export *)
               AST.Seq (assign, statement))
             assignments
             (AST.Call (name, args))
         in
         AST.Subshell command
       )

  | Async _ ->
     raise (NotSupported ("the asynchronous separator & is not supported"))

  | Seq (first, second) ->
     let first = command__to__statement first in
     let second = command__to__statement second in
     AST.Seq (first, second)

  | And (first, second) ->
     let first = command__to__statement first in
     let second = command__to__statement second in
     AST.If (first, second, AST.Not (AST.Call ("false", [])))

  | Or (first, second) ->
     let first = command__to__statement first in
     let second = command__to__statement second in
     AST.If (first, AST.Call ("true", []), second)

  | Not command ->
     let statement = command__to__statement command in
     AST.Not statement

  | Pipe (first, second) ->
     let first = command__to__statement first in
     let second = command__to__statement second in
     AST.Pipe (first, second)

  | Subshell command ->
     let statement = command__to__statement command in
     AST.Subshell statement

  | For (_, None, _) ->
     raise (NotSupported "for with no list")

  | For (name, Some literals, command) ->
     let statement = command__to__statement command in
     AST.Foreach (name, List.map word__to__literal literals, statement)

  | Case (w, cil) ->
     let cil =
       List.fold_right
         (fun ci cil ->
           let ci = case_item__to__case_item ci in
           ci :: cil)
         cil []
     in
     AST.Case (word__to__expression w, cil)

  | If (test, body, None) ->
     let test = command__to__statement test in
     let body = command__to__statement body in
     AST.If (test, body, AST.Call ("true", []))

  | If (test, body, Some rest) ->
     let test = command__to__statement test in
     let body = command__to__statement body in
     let rest = command__to__statement rest in
     AST.If (test, body, rest)

  | While (cond, body) ->
     AST.While (command__to__statement cond,
                command__to__statement body)

  | Until (_cond, _body) ->
     raise (NotSupported "until")

  | Function _ ->
     raise (NotSupported ("function"))

  | Redirection _ as command ->
     redirection__to__statement command

  | HereDocument _ ->
     raise (NotSupported ("here document"))

and case_item__to__case_item (pattern, command) =
  (
    pattern__to__pattern pattern,
    match command with
    | Some command -> command__to__statement command
    | None -> AST.Call ("true", [])
  )

and redirection__to__statement = function
  (* >=2 redirected to /dev/null. Since they don't have any impact on
     the semantics of the program, we don't care. *)
  | Redirection (command, descr, Output, [Literal "/dev/null"])
       when descr >= 2 ->
     command__to__statement command

  (* 1 redirected to >=2, this means the output will never ever have
     an impact on the semantics again ==> ignore *)
  | Redirection (command, 1, OutputDuplicate, [Literal i])
       when (try int_of_string i >= 2 with Failure _ ->  false) ->
     AST.Ignore (command__to__statement command)

  (* 1 redirected to /dev/null. This means that the output will never
     have an impact on the semantics again ==> Ignore. In fact, we can
     even be a bit better an accept all subsequent redirections of >=2
     to 1. *)
  | Redirection (command, 1, Output, [Literal "/dev/null"]) ->
     (
       let rec flush_redirections_to_1 = function
         | Redirection (command, descr, OutputDuplicate, [Literal "1"])
              when descr >= 2 ->
            flush_redirections_to_1 command
         | _ as command -> command
       in
       AST.Ignore (command__to__statement (flush_redirections_to_1 command))
     )

  | _ -> raise (NotSupported ("other redirections"))

and command_list__to__statement = function
  | [] -> raise (NotSupported "empty command list")
  | first :: rest ->
     List.fold_left
       (fun statement command ->
         let statement' = command__to__statement command in
         AST.Seq (statement, statement'))
       (command__to__statement first)
       rest
