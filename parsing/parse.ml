(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Entry points in the parser *)

(* Skip tokens to the end of the phrase *)

let last_token = ref Parser.EOF

let token lexbuf =
  let token = Lexer.token lexbuf in
  last_token := token;
  token

let rec skip_phrase lexbuf =
  match token lexbuf with
  | Parser.SEMISEMI | Parser.EOF -> ()
  | _ -> skip_phrase lexbuf
  | exception (Lexer.Error (Lexer.Unterminated_comment _, _)
              | Lexer.Error (Lexer.Unterminated_string, _)
              | Lexer.Error (Lexer.Unterminated_string_in_comment _, _)
              | Lexer.Error (Lexer.Illegal_character _, _)) ->
      skip_phrase lexbuf

let maybe_skip_phrase lexbuf =
  match !last_token with
  | Parser.SEMISEMI | Parser.EOF -> ()
  | _ -> skip_phrase lexbuf

let wrap parsing_fun lexbuf =
  try
    Docstrings.init ();
    Lexer.init ();
    let ast = parsing_fun lexbuf in
    Parsing.clear_parser();
    Docstrings.warn_bad_docstrings ();
    last_token := Parser.EOF;
    ast
  with
  | Lexer.Error(Lexer.Illegal_character _, _) as err
    when !Location.input_name = "//toplevel//"->
      skip_phrase lexbuf;
      raise err
  | Syntaxerr.Error _ as err
    when !Location.input_name = "//toplevel//" ->
      maybe_skip_phrase lexbuf;
      raise err
  | Parsing.Parse_error | Syntaxerr.Escape_error ->
      let loc = Location.curr lexbuf in
      if !Location.input_name = "//toplevel//"
      then maybe_skip_phrase lexbuf;
      raise(Syntaxerr.Error(Syntaxerr.Other loc))

let wrap_yacc parsing_fun =
  wrap (fun lexbuf -> parsing_fun token lexbuf)

let implementation = wrap_yacc Parser.implementation
and interface = wrap_yacc Parser.interface
and toplevel_phrase = wrap_yacc Parser.toplevel_phrase
and use_file = wrap_yacc Parser.use_file
and core_type = wrap_yacc Parser.parse_core_type
and expression = wrap_yacc Parser.parse_expression
and pattern = wrap_yacc Parser.parse_pattern

let rec loop lexbuf in_error checkpoint =
  let module I = Parser_menhir.MenhirInterpreter in
  match checkpoint with
  | I.InputNeeded _env ->
      let triple =
        if in_error then
          (* The parser detected an error.
             At this point we don't want to consume input anymore. In the
             top-level, it would translate into waiting for the user to type
             something, just to raise an error at some earlier position, rather
             than just raising the error immediately.

             This worked before with yacc because, AFAICT (@let-def):
             - yacc eagerly reduces "default reduction" (when the next action
               is to reduce the same production no matter what token is read,
               yacc reduces it immediately rather than waiting for that token
               to be read)
             - error productions in OCaml grammar are always in a position that
               allows default reduction ("error" symbol is the last producer,
               and the lookahead token will not be used to disambiguate between
               two possible error rules)
             This solution is fragile because it relies on an optimization
             (default reduction), that changes the semantics of the parser the
             way it is implemented in Yacc (an optimization that changes
             semantics? hmmmm).

             Rather than relying on implementation details of the parser, when
             an error is detected in this loop we stop looking at the input and
             fill the parser with EOF tokens.
             The skip_phrase logic will resynchronize the input stream by
             looking for the next ';;'.  *)
          (Parser.EOF, lexbuf.Lexing.lex_curr_p, lexbuf.Lexing.lex_curr_p)
        else
          let token = token lexbuf in
          (token, lexbuf.Lexing.lex_start_p, lexbuf.Lexing.lex_curr_p)
      in
      let checkpoint = I.offer checkpoint triple in
      loop lexbuf in_error checkpoint
  | I.Shifting _ | I.AboutToReduce _ ->
      loop lexbuf in_error (I.resume checkpoint)
  | I.Accepted v -> v
  | I.Rejected -> raise Parser_menhir.Error
  | I.HandlingError _ ->
      loop lexbuf true (I.resume checkpoint)

let wrap_menhir entry lexbuf =
  let initial = entry lexbuf.Lexing.lex_curr_p in
  wrap (fun lexbuf -> loop lexbuf false initial) lexbuf

let implementation_menhir = wrap_menhir Parser_menhir.Incremental.implementation
and interface_menhir = wrap_menhir Parser_menhir.Incremental.interface
and toplevel_phrase_menhir = wrap_menhir Parser_menhir.Incremental.toplevel_phrase
and use_file_menhir = wrap_menhir Parser_menhir.Incremental.use_file
and core_type_menhir = wrap_menhir Parser_menhir.Incremental.parse_core_type
and expression_menhir = wrap_menhir Parser_menhir.Incremental.parse_expression
and pattern_menhir = wrap_menhir Parser_menhir.Incremental.parse_pattern
