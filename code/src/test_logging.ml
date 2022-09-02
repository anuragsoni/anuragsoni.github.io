open! Core

module Id : sig
  type t [@@deriving equal]

  val create : unit -> t
  val to_hex : t -> string
end = struct
  let fill_64_bits state buf ~pos =
    assert (Bytes.length buf - pos >= 8);
    let a = Random.State.bits state in
    let b = Random.State.bits state in
    let c = Random.State.bits state in
    Bytes.unsafe_set buf pos (Char.of_int_exn (a land 0xFF));
    Bytes.unsafe_set buf (pos + 1) (Char.of_int_exn ((a lsr 8) land 0xFF));
    Bytes.unsafe_set buf (pos + 2) (Char.of_int_exn ((a lsr 16) land 0xFF));
    Bytes.unsafe_set buf (pos + 3) (Char.of_int_exn (b land 0xFF));
    Bytes.unsafe_set buf (pos + 4) (Char.of_int_exn ((b lsr 8) land 0xFF));
    Bytes.unsafe_set buf (pos + 5) (Char.of_int_exn ((b lsr 16) land 0xFF));
    Bytes.unsafe_set buf (pos + 6) (Char.of_int_exn (c land 0xFF));
    Bytes.unsafe_set buf (pos + 7) (Char.of_int_exn ((c lsr 8) land 0xFF))
  ;;

  let fill_128_bits state buf ~pos =
    fill_64_bits state buf ~pos;
    fill_64_bits state buf ~pos:(pos + 8)
  ;;

  type t = string [@@deriving equal]

  let create () =
    let b = Bytes.create 16 in
    fill_128_bits Random.State.default b ~pos:0;
    Bytes.unsafe_to_string ~no_mutation_while_string_reachable:b
  ;;

  let to_hex t = Hex_encode.to_hex ~case:`Lowercase t
end

let%expect_test "Can create unique identifiers" =
  for _ = 0 to 4 do
    printf "%s\n" (Id.to_hex (Id.create ()))
  done;
  [%expect
    {|
      be98422c6eec6490a26d766797a4c7cd
      8687af630bd7d57800d0fa24606717d2
      d8efdf0873006fce973345ef71a9d99d
      947eab175189e8df9bba91559ac84f5c
      c1d4a401b57979e1abe3a9407afdaf22 |}]
;;

open! Async

module Logger : sig
  include Log.Global_intf

  val with_transaction : (unit -> 'a Deferred.t) -> 'a Deferred.t
  val log_transform : (Log.Message.t -> Log.Message.t) option
end = struct
  include Log.Make_global ()

  let tag_key = Univ_map.Key.create ~name:"log_tags" [%sexp_of: (string * string) list]

  let merge_tags left right =
    [ left; right ]
    |> List.concat
    |> List.sort ~compare:(fun (key1, _) (key2, _) -> String.Caseless.compare key1 key2)
    |> List.remove_consecutive_duplicates
         ~which_to_keep:`Last
         ~equal:(fun (key1, _) (key2, _) -> String.Caseless.equal key1 key2)
  ;;

  let with_tags tags f =
    let existing_tags = Option.value ~default:[] (Scheduler.find_local tag_key) in
    Scheduler.with_local
      tag_key
      (Some (merge_tags existing_tags tags))
      ~f:(fun () -> Scheduler.within' (fun () -> f ()))
  ;;

  let add_tags_if_present existing_tags =
    match Scheduler.find_local tag_key with
    | None -> existing_tags
    | Some tags -> merge_tags tags existing_tags
  ;;

  let log_transform =
    Some
      (fun msg ->
        let open Log.Message in
        let level = level msg
        and raw_message = raw_message msg
        and tags = add_tags_if_present (tags msg)
        and time = time msg in
        create ?level ~tags ~time raw_message)
  ;;

  let with_transaction f =
    let id = Id.to_hex (Id.create ()) in
    with_tags [ "trace.id", id ] (fun () -> f ())
  ;;

  let () =
    (* Setup log transform at application startup. We also set the transform the global
       logger so tag propagation works within the global logger as well. *)
    set_transform log_transform;
    Log.Global.set_transform log_transform
  ;;
end

module Output = struct
  let json writer =
    let log_level_to_string = function
      | None -> `Null
      | Some level -> `String (Log.Level.to_string level)
    in
    Log.Output.create
      ~flush:(fun () -> Writer.flushed writer)
      (fun messages ->
        Queue.iter messages ~f:(fun message ->
          let tags =
            match Log.Message.tags message with
            | [] -> []
            | tags -> List.map tags ~f:(fun (k, v) -> k, `String v)
          in
          let message =
            ("@timestamp", `String (Time.to_string_utc (Log.Message.time message)))
            :: ("message", `String (Log.Message.message message))
            :: ("log.level", log_level_to_string (Log.Message.level message))
            :: tags
          in
          Writer.write_line writer (Jsonaf.to_string (`Object message)));
        Deferred.unit)
  ;;
end

let stdout = Lazy.force Writer.stdout

let another_function () =
  Logger.info "Hello from another function";
  Logger.with_transaction (fun () ->
    Logger.error "This is an error";
    Logger.info "foobar";
    Logger.with_transaction (fun () ->
      Logger.debug "baz";
      Deferred.unit))
;;
