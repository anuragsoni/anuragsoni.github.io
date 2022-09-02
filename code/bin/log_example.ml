open! Core
open! Async

type example_kind =
  | Default
  | Interleaved
  | Json
  | Correlated
[@@deriving sexp]

let example_kind_of_string input =
  match String.lowercase input with
  | "default" -> Default
  | "interleaved" -> Interleaved
  | "json" -> Json
  | "correlated" -> Correlated
  | _ -> Error.raise_s [%message "Unknown example kind requested" ~input]
;;

let example_kind_arg = Command.Arg_type.map Command.Param.string ~f:example_kind_of_string

let default () =
  Log.Global.set_level `Debug;
  Log.Global.info "This is a log message";
  Log.Global.debug ~tags:[ "user", "abcdef" ] "Send confirmation email";
  Deferred.unit
;;

let sleep_random () =
  let span =
    Time.Span.randomize
      (Time.Span.of_sec (Random.float 1.))
      ~percent:(Percent.of_mult (Random.float 1.))
  in
  after span
;;

let task identifier =
  let%bind () = sleep_random () in
  Log.Global.debug "Starting task: %s" identifier;
  let%bind () = sleep_random () in
  Log.Global.debug "Finished first stage: %s" identifier;
  let%bind () = sleep_random () in
  Log.Global.debug "Finished second stage: %s" identifier;
  let%map () = sleep_random () in
  Log.Global.info "Finished task: %s" identifier
;;

module Output = Code_examples.Test_logging.Output
module Logger = Code_examples.Test_logging.Logger

let correlated () =
  let stdout = Lazy.force Writer.stdout in
  Log.Global.set_output [ Output.json stdout ];
  Log.Global.set_level `Debug;
  Logger.with_transaction (fun () ->
    Log.Global.debug "Starting tasks";
    let%map () = Logger.with_transaction (fun () -> task "A")
    and () = Logger.with_transaction (fun () -> task "B")
    and () = Logger.with_transaction (fun () -> task "C") in
    Log.Global.info "Finished all tasks")
;;

let task identifier =
  let%bind () = sleep_random () in
  Log.Global.debug "Starting task: %s" identifier;
  let%bind () = sleep_random () in
  Log.Global.debug "Finished first stage";
  let%bind () = sleep_random () in
  Log.Global.debug "Finished second stage";
  let%map () = sleep_random () in
  Log.Global.info "Finished task"
;;

let interleaved () =
  Log.Global.set_level `Debug;
  let%map () = task "A"
  and () = task "B"
  and () = task "C" in
  Log.Global.info "Finished all tasks"
;;

let json_logs () =
  let stdout = Lazy.force Writer.stdout in
  Log.Global.set_output [ Output.json stdout ];
  interleaved ()
;;

let main example_kind =
  match example_kind with
  | Default -> default ()
  | Interleaved -> interleaved ()
  | Json -> json_logs ()
  | Correlated -> correlated ()
;;

let command =
  Command.async
    ~summary:"Logging example using Async"
    (let%map_open.Command example_kind = anon ("example_kind" %: example_kind_arg) in
     fun () -> main example_kind)
;;

let () = Command_unix.run command
