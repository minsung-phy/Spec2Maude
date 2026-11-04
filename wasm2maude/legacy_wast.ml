(* WAST script forms of the Wasm 1.0 test suite that the current reference
   parser (vendor/wasm, Wasm 3.0) no longer reads, rewritten to their current
   equivalents. Lines are kept, so source positions stay the same.

   (assert_return_canonical_nan A)  -> (assert_return A (f32.const nan:canonical))
   (assert_return_arithmetic_nan A) -> (assert_return A (f32.const nan:arithmetic))
     The f32 is a placeholder: the planned result takes the type of the
     invoked function's result (Wast_plan, legacy NaN results).
   (elem N (offset) f ..)  -> (elem (table N) (offset) func f ..)
   (data N (offset) s ..)  -> (data (memory N) (offset) s ..)
     Only when N, a number (or, with ids, a $name: Wasm 1.0 segments have no
     names of their own), is followed by an offset expression; an inline
     table segment (elem f ..) keeps its form. *)

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

let normalize ~ids text =
  let n = String.length text in
  let out = Buffer.create (n + 1024) in
  let starts_with i s =
    i + String.length s <= n && String.sub text i (String.length s) = s
  in
  (* The end (exclusive) of the s-expression, string, or comment at i. *)
  let rec skip_string i =
    if i >= n then n
    else if text.[i] = '\\' then skip_string (i + 2)
    else if text.[i] = '"' then i + 1
    else skip_string (i + 1)
  in
  let rec skip_block_comment depth i =
    if i >= n then n
    else if starts_with i "(;" then skip_block_comment (depth + 1) (i + 2)
    else if starts_with i ";)" then
      if depth = 1 then i + 2 else skip_block_comment (depth - 1) (i + 2)
    else skip_block_comment depth (i + 1)
  in
  let rec skip_line i = if i >= n || text.[i] = '\n' then i else skip_line (i + 1) in
  let rec sexp_end depth i =
    if i >= n then n
    else if text.[i] = '"' then sexp_end depth (skip_string (i + 1))
    else if starts_with i "(;" then sexp_end depth (skip_block_comment 1 (i + 2))
    else if starts_with i ";;" then sexp_end depth (skip_line i)
    else if text.[i] = '(' then sexp_end (depth + 1) (i + 1)
    else if text.[i] = ')' then
      if depth = 1 then i + 1 else sexp_end (depth - 1) (i + 1)
    else sexp_end depth (i + 1)
  in
  let rec skip_spaces i = if i < n && is_space text.[i] then skip_spaces (i + 1) else i in
  let number_end i =
    let rec go j =
      if j < n && (Char.code text.[j] >= Char.code '0' && Char.code text.[j] <= Char.code '9'
                   || text.[j] = 'x' || text.[j] = '_'
                   || (Char.lowercase_ascii text.[j] >= 'a' && Char.lowercase_ascii text.[j] <= 'f'))
      then go (j + 1) else j
    in
    let rec name j =
      if j < n && not (is_space text.[j]) && text.[j] <> '(' && text.[j] <> ')'
      then name (j + 1) else j
    in
    if i < n && text.[i] >= '0' && text.[i] <= '9' then Some (go i)
    else if ids && i < n && text.[i] = '$' then Some (name (i + 1))
    else None
  in
  (* [stack] holds, for each open form, the text to add before its ')'. *)
  let rec go i stack =
    if i >= n then ()
    else if text.[i] = '"' then (
      let j = skip_string (i + 1) in
      Buffer.add_string out (String.sub text i (j - i));
      go j stack)
    else if starts_with i "(;" then (
      let j = skip_block_comment 1 (i + 2) in
      Buffer.add_string out (String.sub text i (j - i));
      go j stack)
    else if starts_with i ";;" then (
      let j = skip_line i in
      Buffer.add_string out (String.sub text i (j - i));
      go j stack)
    else if starts_with i "(assert_return_canonical_nan" then (
      Buffer.add_string out "(assert_return";
      go (i + String.length "(assert_return_canonical_nan")
        (" (f32.const nan:canonical)" :: stack))
    else if starts_with i "(assert_return_arithmetic_nan" then (
      Buffer.add_string out "(assert_return";
      go (i + String.length "(assert_return_arithmetic_nan")
        (" (f32.const nan:arithmetic)" :: stack))
    else if starts_with i "(elem" || starts_with i "(data" then (
      let keyword, wrapper =
        if starts_with i "(elem" then "(elem", "table" else "(data", "memory"
      in
      let k = i + String.length keyword in
      let index_start = skip_spaces k in
      match number_end index_start with
      | Some index_end when index_start > k ->
          let offset_start = skip_spaces index_end in
          if offset_start < n && text.[offset_start] = '(' then (
            let index = String.sub text index_start (index_end - index_start) in
            let offset_end = sexp_end 0 offset_start in
            Buffer.add_string out
              (Printf.sprintf "%s (%s %s)%s" keyword wrapper index
                 (String.sub text index_end (offset_end - index_end)));
            if keyword = "(elem" then Buffer.add_string out " func";
            go offset_end ("" :: stack))
          else (
            Buffer.add_string out keyword;
            go k ("" :: stack))
      | Some _ | None ->
          Buffer.add_string out keyword;
          go k ("" :: stack))
    else if text.[i] = '(' then (
      Buffer.add_char out '(';
      go (i + 1) ("" :: stack))
    else if text.[i] = ')' then (
      (match stack with
       | suffix :: _ -> Buffer.add_string out suffix
       | [] -> ());
      Buffer.add_char out ')';
      go (i + 1) (match stack with _ :: rest -> rest | [] -> []))
    else (
      Buffer.add_char out text.[i];
      go (i + 1) stack)
  in
  go 0 [];
  Buffer.contents out
