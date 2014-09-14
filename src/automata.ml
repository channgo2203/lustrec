(********************************************************************)
(*                                                                  *)
(*  The LustreC compiler toolset   /  The LustreC Development Team  *)
(*  Copyright 2012 -    --   ONERA - CNRS - INPT                    *)
(*                                                                  *)
(*  LustreC is free software, distributed WITHOUT ANY WARRANTY      *)
(*  under the terms of the GNU Lesser General Public License        *)
(*  version 2.1.                                                    *)
(*                                                                  *)
(********************************************************************)

open Utils
open LustreSpec
open Corelang

let mkbool loc b =
 mkexpr loc (Expr_const (const_of_bool b))

let mkident loc id =
 mkexpr loc (Expr_ident id)

let mkfby loc e1 e2 =
 mkexpr loc (Expr_arrow (e1, mkexpr loc (Expr_pre e2)))

let mkidentpair loc restart state =
 mkexpr loc (Expr_tuple [mkident loc restart; mkident loc state])

let add_branch (loc, expr, restart, st) cont =
 mkexpr loc (Expr_ite (expr, mkexpr loc (Expr_tuple [mkbool loc restart; mkident loc st]), cont))

let mkhandler loc st unless until locals (stmts, asserts, annots) =
 {hand_state = st;
  hand_unless = unless;
  hand_until = until;
  hand_locals = locals;
  hand_stmts = stmts;
  hand_asserts = asserts;
  hand_annots = annots;
  hand_loc = loc}

let mkautomata loc id handlers =
  {aut_id = id;
   aut_handlers = handlers;
   aut_loc = loc}

let rec handler_read reads handler =
  let locals = List.fold_left (fun locals v -> ISet.add v.var_id locals) ISet.empty handler.hand_locals in
  let allvars =
    List.fold_left (fun read stmt ->
      match stmt with
      | Eq eq -> get_expr_vars read eq.eq_rhs
      | Aut aut -> List.fold_left handler_read read aut.aut_handlers ) reads handler.hand_stmts
  in ISet.diff allvars locals

let rec handler_write writes handler =
  let locals = List.fold_left (fun locals v -> ISet.add v.var_id locals) ISet.empty handler.hand_locals in
  let allvars =
    List.fold_left (fun write stmt ->
      match stmt with
      | Eq eq -> List.fold_left (fun write v -> ISet.add v write) write eq.eq_lhs
      | Aut aut -> List.fold_left handler_write write aut.aut_handlers) writes handler.hand_stmts
  in ISet.diff allvars locals

let rename_output used name = mk_new_name used (Format.sprintf "%s_out" name)

let rec rename_stmts_outputs frename stmts =
  match stmts with
  | []           -> []
  | (Eq eq) :: q   -> let eq' = Eq { eq with eq_lhs = List.map frename eq.eq_lhs } in
		      eq' :: rename_stmts_outputs frename q
  | (Aut aut) :: q -> let handlers' = List.map (fun h -> { h with hand_stmts = rename_stmts_outputs frename h.hand_stmts}) aut.aut_handlers in
                      let aut' = Aut { aut with aut_handlers = handlers' } in
		      aut' :: rename_stmts_outputs frename q

let mk_frename used outputs =
  let table = ISet.fold (fun name table -> IMap.add name (rename_output used name) table) outputs IMap.empty in
  (fun name -> try IMap.find name table with Not_found -> name)
  
let node_of_handler nused used node aut_id handler =
  let outputs = handler_write ISet.empty handler in
  let (new_locals, inputs) = ISet.partition (fun v -> ISet.mem v outputs) (handler_read ISet.empty handler) in
  let frename = mk_frename used outputs in
  let var_inputs = List.map (fun v -> get_node_var v node) (ISet.elements inputs) in
  let new_var_locals = List.map (fun v -> get_node_var v node) (ISet.elements new_locals) in
  let var_outputs = List.map (fun v -> get_node_var v node) (ISet.elements outputs) in
  let new_var_outputs = List.map (fun vdecl -> { vdecl with var_id = frename vdecl.var_id }) var_outputs in
  let new_output_eqs = List.map2 (fun o o' -> Eq (mkeq handler.hand_loc ([o'.var_id], mkident handler.hand_loc o.var_id))) var_outputs new_var_outputs in
  var_outputs,
  {
    node_id = mk_new_name nused (Format.sprintf "%s_%s_handler" aut_id handler.hand_state);
    node_type = Types.new_var ();
    node_clock = Clocks.new_var true;
    node_inputs = var_inputs;
    node_outputs = new_var_outputs;
    node_locals = new_var_locals @ handler.hand_locals;
    node_gencalls = [];
    node_checks = [];
    node_asserts = handler.hand_asserts; 
    node_stmts = new_output_eqs @ handler.hand_stmts;
    node_dec_stateless = false;
    node_stateless = None;
    node_spec = None;
    node_annot = handler.hand_annots
  }

let expr_of_exit loc restart state conds tag =
  mkexpr loc (Expr_when (List.fold_right add_branch conds (mkidentpair loc restart state), state, tag))

let expr_of_handler loc restart state node tag =
  let args = List.map (fun v -> mkexpr loc (Expr_when (mkident loc v.var_id, state, tag))) node.node_inputs in
  let arg = mkexpr loc (Expr_tuple args) in
  let reset = Some (mkident loc restart) in
  mkexpr loc (Expr_appl (node.node_id, arg, reset))

let assign_aut_handlers loc actual_r actual_s hnodes =
  let outputs = fst (snd (List.hd hnodes)) in
  let assign_handlers = List.map (fun (hs, (_, n)) -> (hs, expr_of_handler loc actual_r actual_s n hs)) hnodes in
  let assign_expr = mkexpr loc (Expr_merge (actual_s, assign_handlers)) in
  let assign_eq = mkeq loc (List.map (fun v -> v.var_id) outputs, assign_expr) in
  assign_eq

let typedef_of_automata aut =
  let tname = Format.sprintf "%s_type" aut.aut_id in
  { tydef_id = tname;
    tydef_desc = Tydec_enum (List.map (fun h -> h.hand_state) aut.aut_handlers)
  }
(*
let expand_automata nused used owner typedef node aut =
  let initial = (List.hd aut.aut_handlers).hand_state in
  let incoming_r = mk_new_name used (aut.aut_id ^ "__restart_in") in
  let incoming_s = mk_new_name used (aut.aut_id ^ "__state_in") in
  let actual_r = mk_new_name used (aut.aut_id ^ "__restart_act") in
  let actual_s = mk_new_name used (aut.aut_id ^ "__state_act") in
  let next_incoming_r = mk_new_name used (aut.aut_id ^ "__next_restart_in") in
  let next_incoming_s = mk_new_name used (aut.aut_id ^ "__next_state_in") in
  (* merge on incoming_s gives actual_s by the unless equations *)
  let actual_handlers = List.map (fun h -> (h.hand_state, expr_of_exit h.hand_loc incoming_r incoming_s h.hand_unless h.hand_state)) aut.aut_handlers in
  let actual_expr = mkexpr aut.aut_loc (Expr_merge (incoming_s, unless_handlers)) in
  let actual_eq = mkeq aut.aut_loc ([actual_r; actual_s], unless_expr) in
  (* next_incoming_s and initial conditions gives incoming_s *)
  let incoming_expr = mkfby aut.aut_loc (mkidentpair aut.aut_loc tag_false initial) (mkidentpair aut.aut_loc next_incoming_r next_incoming_s) in
  let incoming_eq = mkeq aut.aut_loc ([incoming_r; incoming_s], incoming_expr) in
  (* merge on actual_s gives handler assigned variables and next_incoming_s by the until equations *)
  let until_handlers = List.map (fun h -> (h.hand_state, expr_of_exit h.hand_loc actual_r actual_s h.hand_until h.hand_state)) aut.aut_handlers in
  let until_expr = mkexpr aut.aut_loc (Expr_merge (actual_s, until_handlers)) in
  let fby_until_expr = mkfby aut.aut_loc (mkidentpair aut.aut_loc tag_false initial) until_expr in
  let until_eq = mkeq aut.aut_loc ([incoming_r; incoming_s], fby_until_expr) in
  let hnodes = List.map (fun h -> (h.hand_state, node_of_handler nused used node aut.aut_id h)) aut.aut_handlers in
  let outputs = fst (snd (List.hd hnodes)) in
  let next_incoming_and_assigned_vars = next_incoming_r :: next_incoming_s :: List.map (fun v -> v.var_id) outputs in
  let next_incoming_and_assigned_handlers =
    List.map (fun h -> ) aut.aut_handlers in
  let next_incoming_and_assigned_expr = mkexpr loc (Expr_merge (actual_s, next_incoming_and_assigned_handlers) in
  let next_incoming_and_assigned_eq = mkeq aut.aut_loc (next_incoming_and_assigned_vars, next_incoming_and_assigned_expr) in
  (* declaration of new local variables, equations and handler nodes *)
  let tydec_bool = { ty_dec_desc = Tydec_bool; ty_dec_loc = aut.aut_loc } in
  let tydec_state id = { ty_dec_desc = Tydec_clock (Tydec_const id); ty_dec_loc = aut.aut_loc } in
  let ckdec_any = { ck_dec_desc = Ckdec_any; ck_dec_loc = aut.aut_loc } in
  let locals' = [mkvar_decl aut.aut_loc (incoming_r, tydec_bool, ckdec_any, false);
                 mkvar_decl aut.aut_loc (actual_r  , tydec_bool, ckdec_any, false);
                 mkvar_decl aut.aut_loc (next_incoming_r  , tydec_bool, ckdec_any, false);
                 mkvar_decl aut.aut_loc (incoming_s, tydec_state typedef.tydef_id, ckdec_any, false);
                 mkvar_decl aut.aut_loc (actual_s  , tydec_state typedef.tydef_id, ckdec_any, false);
                 mkvar_decl aut.aut_loc (next_incoming_s, tydec_state typedef.tydef_id, ckdec_any, false)] in
  let eqs' = [Eq actual_eq; Eq next_incoming_and_assigned_eq; Eq incoming_eq] in
  (List.map2 (fun h (hs, (_, n)) -> mktop_decl h.hand_loc owner false (Node n)) aut.aut_handlers hnodes,
  locals',
  eqs')
*)

let expand_automata nused used owner typedef node aut =
  let initial = (List.hd aut.aut_handlers).hand_state in
  let incoming_r = mk_new_name used (aut.aut_id ^ "__restart_in") in
  let incoming_s = mk_new_name used (aut.aut_id ^ "__state_in") in
  let actual_r = mk_new_name used (aut.aut_id ^ "__restart_act") in
  let actual_s = mk_new_name used (aut.aut_id ^ "__state_act") in
  let unless_handlers = List.map (fun h -> (h.hand_state, expr_of_exit h.hand_loc incoming_r incoming_s h.hand_unless h.hand_state)) aut.aut_handlers in
  let unless_expr = mkexpr aut.aut_loc (Expr_merge (incoming_s, unless_handlers)) in
  let unless_eq = mkeq aut.aut_loc ([actual_r; actual_s], unless_expr) in
  let until_handlers = List.map (fun h -> (h.hand_state, expr_of_exit h.hand_loc actual_r actual_s h.hand_until h.hand_state)) aut.aut_handlers in
  let until_expr = mkexpr aut.aut_loc (Expr_merge (actual_s, until_handlers)) in
  let fby_until_expr = mkfby aut.aut_loc (mkidentpair aut.aut_loc tag_false initial) until_expr in
  let until_eq = mkeq aut.aut_loc ([incoming_r; incoming_s], fby_until_expr) in
  let hnodes = List.map (fun h -> (h.hand_state, node_of_handler nused used node aut.aut_id h)) aut.aut_handlers in
  let assign_eq = assign_aut_handlers aut.aut_loc actual_r actual_s hnodes in
  let tydec_bool = { ty_dec_desc = Tydec_bool; ty_dec_loc = aut.aut_loc } in
  let tydec_state id = { ty_dec_desc = Tydec_clock (Tydec_const id); ty_dec_loc = aut.aut_loc } in
  let ckdec_any = { ck_dec_desc = Ckdec_any; ck_dec_loc = aut.aut_loc } in
  let locals' = [mkvar_decl aut.aut_loc (incoming_r, tydec_bool, ckdec_any, false);
                 mkvar_decl aut.aut_loc (actual_r  , tydec_bool, ckdec_any, false);
                 mkvar_decl aut.aut_loc (incoming_s, tydec_state typedef.tydef_id, ckdec_any, false);
                 mkvar_decl aut.aut_loc (actual_s  , tydec_state typedef.tydef_id, ckdec_any, false)] in
  let eqs' = [Eq unless_eq; Eq assign_eq; Eq until_eq] in
  (List.map2 (fun h (hs, (_, n)) -> mktop_decl h.hand_loc owner false (Node n)) aut.aut_handlers hnodes,
  locals',
  eqs')

let expand_node_stmt nused used owner node (top_types, top_nodes, locals, eqs) stmt =
  match stmt with
  | Eq eq -> (top_types, top_nodes, locals, (Eq eq)::eqs)
  | Aut aut ->
    let typedef = typedef_of_automata aut in
    let used' name = used name || List.exists (fun v -> v.var_id = name) locals in
    let nused' name =
      nused name ||
      List.exists (fun t -> match t.top_decl_desc with
      | ImportedNode nd -> nd.nodei_id = name | Node nd -> nd.node_id = name
      | _ -> false) top_nodes in
    let (top_decls', locals', eqs') = expand_automata nused' used' owner typedef node aut in
    let top_typedef = mktop_decl aut.aut_loc owner false (TypeDef typedef) in
    (top_typedef :: top_types, top_decls'@top_nodes, locals'@locals, eqs'@eqs)

let expand_node_stmts nused used loc owner node =
  let (top_types', top_nodes', locals', eqs') =
    List.fold_left (expand_node_stmt nused used owner node) ([], [], [], []) node.node_stmts in
  let node' = 
    { node with node_locals = locals'@node.node_locals; node_stmts = eqs' } in
  let top_node = mktop_decl loc owner false (Node node') in
  top_types', top_node, top_nodes'

let rec expand_decls_rec nused top_decls =
  match top_decls with
  | [] -> []
  | top_decl::q ->
    match top_decl.top_decl_desc with
    | Node nd ->
      let used name =
	   List.exists (fun v -> v.var_id = name) nd.node_inputs
	|| List.exists (fun v -> v.var_id = name) nd.node_outputs
	|| List.exists (fun v -> v.var_id = name) nd.node_locals in
      let (top_types', top_decl', top_nodes') = expand_node_stmts nused used top_decl.top_decl_loc top_decl.top_decl_owner nd in
      top_types' @ (top_decl' :: expand_decls_rec nused (top_nodes'@q))
    | _       -> top_decl :: expand_decls_rec nused q

let expand_decls top_decls =
  let top_names = List.fold_left (fun names t -> match t.top_decl_desc with
    | Node nd         -> ISet.add nd.node_id names
    | ImportedNode nd -> ISet.add nd.nodei_id names
    | _               -> names) ISet.empty top_decls in
  let nused name = ISet.mem name top_names in
  expand_decls_rec nused top_decls

(* Local Variables: *)
(* compile-command:"make -C .." *)
(* End: *)
