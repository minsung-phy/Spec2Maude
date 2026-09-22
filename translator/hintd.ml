open Util.Source
open Il.Ast

type t =
  { type_env : Il.Env.t
  ; type_definitions : (string * inst list) list
  }

type sequence_representation =
  { sort : string; empty : string; concat : string; occurs : string
  ; size : string; repeat : string; lift : string }

(* Removed translation contracts must not silently become documentation hints. *)
let scan_sorts script =
  let definitions = ref [] in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_def def =
      match def.it with
      | TypD (id, _, insts) ->
          let previous = Option.value (List.assoc_opt id.it !definitions) ~default:[] in
          definitions := (id.it, previous @ insts) :: List.remove_assoc id.it !definitions
      | HintD hint ->
          let owner, hints = match hint.it with
            | TypH (id, hints) -> "TypH " ^ id.it, hints
            | RelH (id, hints) -> "RelH " ^ id.it, hints
            | DecH (id, hints) -> "DecH " ^ id.it, hints
            | GramH (id, hints) -> "GramH " ^ id.it, hints
            | RuleH (id, rule, hints) -> "RuleH " ^ id.it ^ "/" ^ rule.it, hints
          in
          List.iter (fun hint ->
            if List.mem hint.hintid.it
                ["k_heatcool"; "maude_context"; "maude_sort"; "maude_subsort"; "maude_proper"] then
              Util.Error.error hint.hintid.at "translation"
                ("Unsupported " ^ owner ^ ": removed baseline hint " ^ hint.hintid.it)) hints
      | RelD _ | DecD _ | GramD _ | RecD _ -> ()
  end) in
  Visitor.list Visitor.def script;
  {type_env = Il.Env.env_of_script script; type_definitions = !definitions}

let primitive_sort typ =
  match typ.it with
  | NumT `NatT -> "Nat"
  | NumT `IntT -> "Int"
  | IterT _ -> "SpectecTerminals"
  | VarT _ | BoolT | NumT (`RatT | `RealT) | TextT | TupT _ ->
      "SpectecTerminal"

let common_sort = function
  | sort :: sorts when List.for_all (String.equal sort) sorts -> sort
  | [] | _ -> "SpectecTerminal"

let rec sort_of_typ_seen metadata seen typ =
  match typ.it with
  | VarT (id, _) when not (List.mem id.it seen) ->
      begin match List.assoc_opt id.it metadata.type_definitions with
      | None -> "SpectecTerminal"
      | Some insts ->
          insts
          |> List.map (sort_of_inst metadata (id.it :: seen))
          |> common_sort
      end
  | VarT _ -> "SpectecTerminal"
  | _ -> primitive_sort typ

and sort_of_inst metadata seen inst =
  match inst.it with
  | InstD (_, _, {it = AliasT typ; _}) ->
      sort_of_typ_seen metadata seen typ
  | InstD (_, _, {it = StructT _; _}) ->
      "SpectecTerminal"
  | InstD (_, _, {it = VariantT cases; _}) ->
      cases
      |> List.map (fun (mixop, (typ, _, _), _) ->
           if Mixop.is_hole_only mixop then
             match typ.it with
             | TupT [(_, payload)] -> sort_of_typ_seen metadata seen payload
             | _ -> "SpectecTerminal"
           else "SpectecTerminal")
      |> common_sort

let sort_of_typ metadata typ =
  sort_of_typ_seen metadata [] (Il.Eval.reduce_typ metadata.type_env typ)

let sequence_representation _metadata _typ =
  { sort = "SpectecTerminals"; empty = "eps"; concat = "_ _"
  ; occurs = "_<-_"; size = "len"; repeat = "repeatSeq"; lift = "lift" }

let representation_inclusion metadata source target =
  sort_of_typ metadata source = sort_of_typ metadata target

let sequence_element_wrappers metadata typ =
  if sort_of_typ metadata typ = "SpectecTerminals" then Some ("seq", "unseq")
  else None
