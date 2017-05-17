open LustreSpec
open Corelang
open Log
open Format

let random_seed = ref 0
let threshold_delay = 95
let threshold_inc_int = 97
let threshold_dec_int = 97
let threshold_random_int = 96
let threshold_switch_int = 100 (* not implemented yet *)
let threshold_random_float = 100 (* not used yet *)
let threshold_negate_bool_var = 95
let threshold_arith_op = 95
let threshold_rel_op = 95
let threshold_bool_op = 95

let int_consts = ref []

let rename_app id = 
  if !Options.no_mutation_suffix then
    id
  else
    id ^ "_mutant"

(************************************************************************************)
(*                    Gathering constants in the code                               *)
(************************************************************************************)

module IntSet = Set.Make (struct type t = int let compare = compare end)
module OpCount = Mmap.Make (struct type t = string let compare = compare end)

type records = {
  consts: IntSet.t;
  nb_boolexpr: int;
  nb_pre: int;
  nb_op: int OpCount.t;
}

let arith_op = ["+" ; "-" ; "*" ; "/"] 
let bool_op = ["&&"; "||"; "xor";  "impl"] 
let rel_op = ["<" ; "<=" ; ">" ; ">=" ; "!=" ; "=" ] 
let ops = arith_op @ bool_op @ rel_op
let all_ops = "not" :: ops

let empty_records = 
  {consts=IntSet.empty; nb_boolexpr=0; nb_pre=0; nb_op=OpCount.empty}

let records = ref empty_records

let merge_records records_list = 
  let merge_record r1 r2 =
    {
      consts = IntSet.union r1.consts r2.consts;

      nb_boolexpr = r1.nb_boolexpr + r2.nb_boolexpr;
      nb_pre = r1.nb_pre + r2.nb_pre;

      nb_op = OpCount.merge (fun op r1opt r2opt ->
	match r1opt, r2opt with
	| None, _ -> r2opt
	| _, None -> r1opt
	| Some x, Some y -> Some (x+y)
      ) r1.nb_op r2.nb_op 
    }
  in
  List.fold_left merge_record empty_records records_list
  
let compute_records_const_value c =
  match c with
  | Const_int i -> {empty_records with consts = IntSet.singleton i}
  | _ -> empty_records

let rec compute_records_expr expr =
  let boolexpr = 
    if (Types.repr expr.expr_type).Types.tdesc = Types.Tbool then
      {empty_records with nb_boolexpr = 1}
    else
      empty_records
  in
  let subrec = 
    match expr.expr_desc with
    | Expr_const c -> compute_records_const_value c
    | Expr_tuple l -> merge_records (List.map compute_records_expr l)
    | Expr_ite (i,t,e) -> 
      merge_records (List.map compute_records_expr [i;t;e])
    | Expr_arrow (e1, e2) ->       
      merge_records (List.map compute_records_expr [e1;e2])
    | Expr_pre e -> 
      merge_records (
	({empty_records with nb_pre = 1})
	::[compute_records_expr e])
    | Expr_appl (op_id, args, r) -> 
      if List.mem op_id ops then
	merge_records (
	  ({empty_records with nb_op = OpCount.singleton op_id 1})
	  ::[compute_records_expr args])
      else
	compute_records_expr args
    | _ -> empty_records
  in
  merge_records [boolexpr;subrec]

let compute_records_eq eq = compute_records_expr eq.eq_rhs

let compute_records_node nd = 
  merge_records (List.map compute_records_eq (get_node_eqs nd))

let compute_records_top_decl td =
  match td.top_decl_desc with
  | Node nd -> compute_records_node nd
  | Const cst -> compute_records_const_value cst.const_value
  | _ -> empty_records

let compute_records prog = 
  merge_records (List.map compute_records_top_decl prog)

(*****************************************************************)
(*                  Random mutation                              *)
(*****************************************************************)

let check_mut e1 e2 =
  let rec eq e1 e2 =
    match e1.expr_desc, e2.expr_desc with
    | Expr_const c1, Expr_const c2 -> c1 = c2
    | Expr_ident id1, Expr_ident id2 -> id1 = id2
    | Expr_tuple el1, Expr_tuple el2 -> List.length el1 = List.length el2 && List.for_all2 eq el1 el2
    | Expr_ite (i1, t1, e1), Expr_ite (i2, t2, e2) -> eq i1 i2 && eq t1 t2 && eq e1 e2
    | Expr_arrow (x1, y1), Expr_arrow (x2, y2) -> eq x1 x2 && eq y1 y2
    | Expr_pre e1, Expr_pre e2 -> eq e1 e2
    | Expr_appl (id1, e1, _), Expr_appl (id2, e2, _) -> id1 = id2 && eq e1 e2
  | _ -> false
  in
  if not (eq e1 e2) then
    Some (e1, e2)
  else
    None

let mk_cst_expr c = mkexpr Location.dummy_loc (Expr_const c)

let rdm_mutate_int i = 
  if Random.int 100 > threshold_inc_int then
    i+1
  else if Random.int 100 > threshold_dec_int then
    i-1
  else if Random.int 100 > threshold_random_int then
    Random.int 10
  else if Random.int 100 > threshold_switch_int then
    let idx = Random.int (List.length !int_consts) in
    List.nth !int_consts idx
  else
    i
  
let rdm_mutate_real r =
  if Random.int 100 > threshold_random_float then
    (* interval [0, bound] for random values *)
    let bound = 10 in
    (* max number of digits after comma *)
    let digits = 5 in
    (* number of digits after comma *)
    let shift = Random.int (digits + 1) in
    let eshift = 10. ** (float_of_int shift) in
    let i = Random.int (1 + bound * (int_of_float eshift)) in
    let f = float_of_int i /. eshift in
    (Num.num_of_int i, shift, string_of_float f)
  else 
    r

let rdm_mutate_op op = 
match op with
| "+" | "-" | "*" | "/" when Random.int 100 > threshold_arith_op ->
  let filtered = List.filter (fun x -> x <> op) ["+"; "-"; "*"; "/"] in
  List.nth filtered (Random.int 3)
| "&&" | "||" | "xor" | "impl" when Random.int 100 > threshold_bool_op ->
  let filtered = List.filter (fun x -> x <> op) ["&&"; "||"; "xor"; "impl"] in
  List.nth filtered (Random.int 3)
| "<" | "<=" | ">" | ">=" | "!=" | "=" when Random.int 100 > threshold_rel_op ->
  let filtered = List.filter (fun x -> x <> op) ["<"; "<="; ">"; ">="; "!="; "="] in
  List.nth filtered (Random.int 5)
| _ -> op


let rdm_mutate_var expr = 
  match (Types.repr expr.expr_type).Types.tdesc with 
  | Types.Tbool ->
    (* if Random.int 100 > threshold_negate_bool_var then *)
    let new_e = mkpredef_call expr.expr_loc "not" [expr] in
    Some (expr, new_e), new_e
    (* else  *)
    (*   expr *)
  | _ -> None, expr
    
let rdm_mutate_pre orig_expr = 
  let new_e = Expr_pre orig_expr in
  Some (orig_expr, {orig_expr with expr_desc = new_e}), new_e


let rdm_mutate_const_value c =
  match c with
  | Const_int i -> Const_int (rdm_mutate_int i)
  | Const_real (n, i, s) -> let (n', i', s') = rdm_mutate_real (n, i, s) in Const_real (n', i', s')
  | Const_array _
  | Const_string _
  | Const_struct _
  | Const_tag _ -> c

let rdm_mutate_const c =
  let new_const = rdm_mutate_const_value c.const_value in
  let mut = check_mut (mk_cst_expr c.const_value) (mk_cst_expr new_const) in
  mut, { c with const_value = new_const }


let select_in_list list rdm_mutate_elem = 
  let selected = Random.int (List.length list) in
  let mutation_opt, new_list, _ = 
    List.fold_right
      (fun elem (mutation_opt, res, cpt) -> if cpt = selected then 
	  let mutation, new_elem = rdm_mutate_elem elem in
	  Some mutation, new_elem::res, cpt+1  else mutation_opt, elem::res, cpt+1)
      list 
      (None, [], 0)
  in
  match mutation_opt with
  | Some mut -> mut, new_list
  | _ -> assert false


let rec rdm_mutate_expr expr =
  let mk_e d = { expr with expr_desc = d } in
  match expr.expr_desc with
  | Expr_ident id -> rdm_mutate_var expr
  | Expr_const c -> 
    let new_const = rdm_mutate_const_value c in 
    let mut = check_mut (mk_cst_expr c) (mk_cst_expr new_const) in
    mut, mk_e (Expr_const new_const)
  | Expr_tuple l -> 
    let mut, l' = select_in_list l rdm_mutate_expr in
    mut, mk_e (Expr_tuple l')
  | Expr_ite (i,t,e) -> (
    let mut, l = select_in_list [i; t; e] rdm_mutate_expr in
    match l with
    | [i'; t'; e'] -> mut, mk_e (Expr_ite (i', t', e'))
    | _ -> assert false
  )
  | Expr_arrow (e1, e2) -> (
    let mut, l = select_in_list [e1; e2] rdm_mutate_expr in
    match l with
    | [e1'; e2'] -> mut, mk_e (Expr_arrow (e1', e2'))
    | _ -> assert false
  )
  | Expr_pre e -> 
    let select_pre = Random.bool () in
    if select_pre then
      let mut, new_expr = rdm_mutate_pre expr in
      mut, mk_e new_expr
    else
      let mut, e' = rdm_mutate_expr e in
      mut, mk_e (Expr_pre e')
  | Expr_appl (op_id, args, r) -> 
    let select_op = Random.bool () in
    if select_op then
      let new_op_id = rdm_mutate_op op_id in
      let new_e = mk_e (Expr_appl (new_op_id, args, r)) in
      let mut = check_mut expr new_e in
      mut, new_e
    else
      let mut, new_args = rdm_mutate_expr args in
      mut, mk_e (Expr_appl (op_id, new_args, r))
  (* Other constructs are kept.
  | Expr_fby of expr * expr
  | Expr_array of expr list
  | Expr_access of expr * Dimension.dim_expr
  | Expr_power of expr * Dimension.dim_expr
  | Expr_when of expr * ident * label
  | Expr_merge of ident * (label * expr) list
  | Expr_uclock of expr * int
  | Expr_dclock of expr * int
  | Expr_phclock of expr * rat *)
   | _ -> None, expr
  

let rdm_mutate_eq eq =
  let mutation, new_rhs = rdm_mutate_expr eq.eq_rhs in
  mutation, { eq with eq_rhs = new_rhs }

let rnd_mutate_stmt stmt =
  match stmt with
  | Eq eq   -> let mut, new_eq = rdm_mutate_eq eq in
		 report ~level:1 
		   (fun fmt -> fprintf fmt "mutation: %a becomes %a@." 
		     Printers.pp_node_eq eq
		     Printers.pp_node_eq new_eq);
		 mut, Eq new_eq 
  | Aut aut -> assert false

let rdm_mutate_node nd = 
  let mutation, new_node_stmts =       
    select_in_list 
      nd.node_stmts rnd_mutate_stmt
  in
  mutation, { nd with node_stmts = new_node_stmts }

let rdm_mutate_top_decl td =
  match td.top_decl_desc with
  | Node nd -> 
    let mutation, new_node = rdm_mutate_node nd in 
    mutation, { td with top_decl_desc = Node new_node}
  | Const cst -> 
    let mut, new_cst = rdm_mutate_const cst in
    mut, { td with top_decl_desc = Const new_cst }
  | _ -> None, td
    
(* Create a single mutant with the provided random seed *)
let rdm_mutate_prog prog = 
  select_in_list prog rdm_mutate_top_decl

let rdm_mutate nb prog = 
  let rec iterate nb res =
    incr random_seed;
    if nb <= 0 then
      res
    else (
      Random.init !random_seed;
      let mutation, new_mutant = rdm_mutate_prog prog in
      match mutation with
	None -> iterate nb res 
      | Some mutation -> ( 
	if List.mem_assoc mutation res then (
	  iterate nb res
	)
	else (
	  report ~level:1 (fun fmt -> fprintf fmt "%i mutants remaining@." nb); 
	  iterate (nb-1) ((mutation, new_mutant)::res)
	)
      )
    )
  in
  iterate nb []


(*****************************************************************)
(*                  Random mutation                              *)
(*****************************************************************)

type mutant_t = Boolexpr of int | Pre of int | Op of string * int * string | IncrIntCst of int | DecrIntCst of int | SwitchIntCst of int * int 

let target : mutant_t option ref = ref None

let print_directive fmt d =
  match d with
  | Pre n -> Format.fprintf fmt "pre %i" n
  | Boolexpr n -> Format.fprintf fmt "boolexpr %i" n
  | Op (o, i, d) -> Format.fprintf fmt "%s %i -> %s" o i d
  | IncrIntCst n ->  Format.fprintf fmt "incr int cst %i" n
  | DecrIntCst n ->  Format.fprintf fmt "decr int cst %i" n
  | SwitchIntCst (n, m) ->  Format.fprintf fmt "switch int cst %i -> %i" n m

let fold_mutate_int i = 
  if Random.int 100 > threshold_inc_int then
    i+1
  else if Random.int 100 > threshold_dec_int then
    i-1
  else if Random.int 100 > threshold_random_int then
    Random.int 10
  else if Random.int 100 > threshold_switch_int then
    try
	let idx = Random.int (List.length !int_consts) in
        List.nth !int_consts idx
    with _ -> i
  else
    i
  
let fold_mutate_float f =
  if Random.int 100 > threshold_random_float then
    Random.float 10.
  else 
    f

let fold_mutate_op op = 
(* match op with *)
(* | "+" | "-" | "*" | "/" when Random.int 100 > threshold_arith_op -> *)
(*   let filtered = List.filter (fun x -> x <> op) ["+"; "-"; "*"; "/"] in *)
(*   List.nth filtered (Random.int 3) *)
(* | "&&" | "||" | "xor" | "impl" when Random.int 100 > threshold_bool_op -> *)
(*   let filtered = List.filter (fun x -> x <> op) ["&&"; "||"; "xor"; "impl"] in *)
(*   List.nth filtered (Random.int 3) *)
(* | "<" | "<=" | ">" | ">=" | "!=" | "=" when Random.int 100 > threshold_rel_op -> *)
(*   let filtered = List.filter (fun x -> x <> op) ["<"; "<="; ">"; ">="; "!="; "="] in *)
(*   List.nth filtered (Random.int 5) *)
(* | _ -> op *)
  match !target with
  | Some (Op(op_orig, 0, op_new)) when op_orig = op -> (
    target := None;
    op_new
  )
  | Some (Op(op_orig, n, op_new)) when op_orig = op -> (
    target := Some (Op(op_orig, n-1, op_new));
    op
  )
  | _ -> if List.mem op Basic_library.internal_funs then op else rename_app op


let fold_mutate_var expr = 
  (* match (Types.repr expr.expr_type).Types.tdesc with  *)
  (* | Types.Tbool -> *)
  (*     (\* if Random.int 100 > threshold_negate_bool_var then *\) *)
  (*     mkpredef_unary_call Location.dummy_loc "not" expr *)
  (*   (\* else  *\) *)
  (*   (\*   expr *\) *)
  (* | _ -> 
 *)expr

let fold_mutate_boolexpr expr =
  match !target with
  | Some (Boolexpr 0) -> (
    target := None;
    mkpredef_call expr.expr_loc "not" [expr]
  )
  | Some (Boolexpr n) ->
      (target := Some (Boolexpr (n-1)); expr)
  | _ -> expr
    
let fold_mutate_pre orig_expr e = 
  match !target with
    Some (Pre 0) -> (
      target := None;
      Expr_pre ({orig_expr with expr_desc = Expr_pre e}) 
    )
  | Some (Pre n) -> (
    target := Some (Pre (n-1));
    Expr_pre e
  )
  | _ -> Expr_pre e
    
let fold_mutate_const_value c = 
match c with
| Const_int i -> (
  match !target with
  | Some (IncrIntCst 0) -> (target := None; Const_int (i+1))
  | Some (DecrIntCst 0) -> (target := None; Const_int (i-1))
  | Some (SwitchIntCst (0, id)) -> (target := None; Const_int (List.nth (IntSet.elements (IntSet.remove i !records.consts)) id)) 
  | Some (IncrIntCst n) -> (target := Some (IncrIntCst (n-1)); c)
  | Some (DecrIntCst n) -> (target := Some (DecrIntCst (n-1)); c)
  | Some (SwitchIntCst (n, id)) -> (target := Some (SwitchIntCst (n-1, id)); c)
  | _ -> c)
| _ -> c

(*
  match c with
  | Const_int i -> Const_int (fold_mutate_int i)
  | Const_real s -> Const_real s (* those are string, let's leave them *)
  | Const_float f -> Const_float (fold_mutate_float f)
  | Const_array _
  | Const_tag _ -> c
TODO

				  *)
let fold_mutate_const c =
  { c with const_value = fold_mutate_const_value c.const_value }

let rec fold_mutate_expr expr =
  let new_expr = 
    match expr.expr_desc with
    | Expr_ident id -> fold_mutate_var expr
    | _ -> (
      let new_desc = match expr.expr_desc with
	| Expr_const c -> Expr_const (fold_mutate_const_value c)
	| Expr_tuple l -> Expr_tuple (List.fold_right (fun e res -> (fold_mutate_expr e)::res) l [])
	| Expr_ite (i,t,e) -> Expr_ite (fold_mutate_expr i, fold_mutate_expr t, fold_mutate_expr e)
	| Expr_arrow (e1, e2) -> Expr_arrow (fold_mutate_expr e1, fold_mutate_expr e2)
	| Expr_pre e -> fold_mutate_pre expr (fold_mutate_expr e)
	| Expr_appl (op_id, args, r) -> Expr_appl (fold_mutate_op op_id, fold_mutate_expr args, r)
  (* Other constructs are kept.
  | Expr_fby of expr * expr
  | Expr_array of expr list
  | Expr_access of expr * Dimension.dim_expr
  | Expr_power of expr * Dimension.dim_expr
  | Expr_when of expr * ident * label
  | Expr_merge of ident * (label * expr) list
  | Expr_uclock of expr * int
  | Expr_dclock of expr * int
  | Expr_phclock of expr * rat *)
  | _ -> expr.expr_desc
    
      in
      { expr with expr_desc = new_desc }
    )
  in
  if (Types.repr expr.expr_type).Types.tdesc = Types.Tbool then
    fold_mutate_boolexpr new_expr  
  else
    new_expr

let fold_mutate_eq eq =
  { eq with eq_rhs = fold_mutate_expr eq.eq_rhs }

let fold_mutate_stmt stmt =
  match stmt with
  | Eq eq   -> Eq (fold_mutate_eq eq)
  | Aut aut -> assert false

let fold_mutate_node nd = 
  { nd with 
    node_stmts = 
      List.fold_right (fun stmt res -> (fold_mutate_stmt stmt)::res) nd.node_stmts [];
    node_id = rename_app nd.node_id
  }

let fold_mutate_top_decl td =
  match td.top_decl_desc with
  | Node nd   -> { td with top_decl_desc = Node  (fold_mutate_node nd)}
  | Const cst -> { td with top_decl_desc = Const (fold_mutate_const cst)}
  | _ -> td
    
(* Create a single mutant with the provided random seed *)
let fold_mutate_prog prog = 
  List.fold_right (fun e res -> (fold_mutate_top_decl e)::res) prog []

let create_mutant prog directive =  
  target := Some directive; 
  let prog' = fold_mutate_prog prog in
  target := None;
  prog'
  

let op_mutation op = 
  let res =
    let rem_op l = List.filter (fun e -> e <> op) l in
  if List.mem op arith_op then rem_op arith_op else 
    if List.mem op bool_op then rem_op bool_op else 
      if List.mem op rel_op then rem_op rel_op else 
	(Format.eprintf "Failing with op %s@." op;
	  assert false
	)
  in
  (* Format.eprintf "Mutation op %s to [%a]@." op (Utils.fprintf_list ~sep:"," Format.pp_print_string) res; *)
  res

let rec remains select list =
  match list with 
    [] -> []
  | hd::tl -> if select hd then tl else remains select tl
      
let next_change m =
  let res = 
  let rec first_op () = 
    try
      let min_binding = OpCount.min_binding !records.nb_op in
      Op (fst min_binding, 0, List.hd (op_mutation (fst min_binding)))
    with Not_found -> first_boolexpr () 
  and first_boolexpr () =
    if !records.nb_boolexpr > 0 then 
      Boolexpr 0 
    else first_pre ()
  and first_pre () = 
    if !records.nb_pre > 0 then 
      Pre 0 
    else
      first_op ()
  and first_intcst () =
    if IntSet.cardinal !records.consts > 0 then
      IncrIntCst 0
    else
      first_boolexpr ()
  in
  match m with
  | Boolexpr n -> 
    if n+1 >= !records.nb_boolexpr then 
      first_pre ()
    else
      Boolexpr (n+1)
  | Pre n -> 
    if n+1 >= !records.nb_pre then 
      first_op ()
    else Pre (n+1)
  | Op (orig, id, mut_op) -> (
    match remains (fun x -> x = mut_op) (op_mutation orig) with
    | next_op::_ -> Op (orig, id, next_op)
    | [] -> if id+1 >= OpCount.find orig !records.nb_op then (
      match remains (fun (k1, _) -> k1 = orig) (OpCount.bindings !records.nb_op) with
      | [] -> first_intcst ()
      | hd::_ -> Op (fst hd, 0, List.hd (op_mutation (fst hd)))
    ) else
	Op(orig, id+1, List.hd (op_mutation orig))
  )
  | IncrIntCst n ->
    if n+1 >= IntSet.cardinal !records.consts then
      DecrIntCst 0
    else IncrIntCst (n+1)
  | DecrIntCst n ->
    if n+1 >= IntSet.cardinal !records.consts then
      SwitchIntCst (0, 0)
    else DecrIntCst (n+1)
  | SwitchIntCst (n, m) ->
    if m+1 > -1 + IntSet.cardinal !records.consts then
      SwitchIntCst (n, m+1)
    else if n+1 >= IntSet.cardinal !records.consts then
      SwitchIntCst (n+1, 0)
    else first_boolexpr ()

  in
  (* Format.eprintf "from: %a to: %a@." print_directive m print_directive res; *)
  res

let fold_mutate nb prog = 
  incr random_seed;
  Random.init !random_seed;
  let find_next_new mutants mutant =
    let rec find_next_new init current =
      if init = current then raise Not_found else
	if List.mem current mutants then
	  find_next_new init (next_change current)
	else
	  current
    in
    find_next_new mutant (next_change mutant) 
  in
  (* Creating list of nb elements of mutants *)
  let rec create_mutants_directives rnb mutants = 
    if rnb <= 0 then mutants 
    else 
      let random_mutation = 
	match Random.int 6 with
	| 5 -> IncrIntCst (try Random.int (IntSet.cardinal !records.consts) with _ -> 0)
	| 4 -> DecrIntCst (try Random.int (IntSet.cardinal !records.consts) with _ -> 0)
	| 3 -> SwitchIntCst ((try Random.int (IntSet.cardinal !records.consts) with _ -> 0), (try Random.int (-1 + IntSet.cardinal !records.consts) with _ -> 0))
	| 2 -> Pre (try Random.int !records.nb_pre with _ -> 0)
	| 1 -> Boolexpr (try Random.int !records.nb_boolexpr with _ -> 0)
	| 0 -> let bindings = OpCount.bindings !records.nb_op in
	       let op, nb_op = List.nth bindings (try Random.int (List.length bindings) with _ -> 0) in
	       let new_op = List.nth (op_mutation op) (try Random.int (List.length (op_mutation op)) with _ -> 0) in
	       Op (op, (try Random.int nb_op with _ -> 0), new_op)
	| _ -> assert false
      in
      if List.mem random_mutation mutants then
	try
	  let new_mutant = (find_next_new mutants random_mutation) in
	  report ~level:2 (fun fmt -> fprintf fmt " %i mutants generated out of %i expected@." (nb-rnb) nb);
	 create_mutants_directives (rnb-1) (new_mutant::mutants) 
	with Not_found -> (
	  report ~level:1 (fun fmt -> fprintf fmt "Only %i mutants generated out of %i expected@." (nb-rnb) nb); 
	  mutants
	)
      else
	create_mutants_directives (rnb-1) (random_mutation::mutants)
  in
  let mutants_directives = create_mutants_directives nb [] in
  List.map (fun d -> d, create_mutant prog d) mutants_directives 
  

let mutate nb prog =
  records := compute_records prog;
  (* Format.printf "Records: %i pre, %i boolexpr" (\* , %a ops *\) *)
  (*   !records.nb_pre *)
(*     !records.nb_boolexpr *)
(*     (\* !records.op *\) *)
(* ;  *)   
  fold_mutate nb prog, print_directive




(* Local Variables: *)
(* compile-command:"make -C .." *)
(* End: *)

    