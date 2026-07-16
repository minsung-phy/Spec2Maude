type 'a pending =
  { key : string
  ; value : 'a
  }

type ('a, 'b) result =
  { completed : 'b list
  ; stalled : 'a pending list
  }

let unique items =
  items
  |> List.fold_left (fun (keys, items) item ->
    if List.mem item.key keys then keys, items
    else item.key :: keys, item :: items) ([], [])
  |> snd |> List.rev

let run ~pending ~materialize =
  let remaining completed =
    pending ()
    |> unique
    |> List.filter (fun item -> not (List.mem item.key completed))
  in
  let rec loop completed outputs =
    match remaining completed with
    | [] -> { completed = List.rev outputs; stalled = [] }
    | items ->
      let progressed, new_outputs =
        items
        |> List.fold_left (fun (keys, outputs) item ->
          match materialize item.value with
          | None -> keys, outputs
          | Some output -> item.key :: keys, output :: outputs) ([], [])
      in
      if progressed = [] then
        let stalled = remaining completed in
        if stalled = [] then { completed = List.rev outputs; stalled = [] }
        else { completed = List.rev outputs; stalled }
      else
        loop (List.rev_append progressed completed)
          (List.rev_append new_outputs outputs)
  in
  loop [] []
