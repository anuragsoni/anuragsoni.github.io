---
title: "Better logging for OCaml + Async"
date: 2022-09-02T08:56:28-04:00
toc: true
tags: [OCaml, logging]
---

## Why?
Effectively running systems in production requires application level support for providing better visibility into what's happening at runtime. Instrumenting applications to provide structured, context aware traces/events is becoming easier thanks to efforts like [OpenTelemetry](https://opentelemetry.io/docs/) [^1], which is a vendor neutral framework for instrumentation and trace collection. 

Using auto-instrumentation, either via OpenTelemetry SDKs for the language of your choice, or an observability vendor specific library has a lot of benefits. These libraries typically come with out of the box support for instrumenting a wide set of libraries, and propagating useful events to a collection agent (Elastic, Honeycomb and more). Structured events also have the benefit of allowing addition of interesting details like unique ids, execution time, etc about an event in question. Unlike logs which is a discrete event, traces span over a time interval. They can be started at the beginning of an interesting event, and allow incrementally adding more context to it over the lifecycle of the trace.

A future post will talk more about leveraging tracing, and the benefits of using that model over manually logging information within applications, but there is still quite a bit we can do to improve logging and make them more useful for use in production systems.

[^1]: OCaml library for OpenTelemetry support https://github.com/imandra-ai/ocaml-opentelemetry

## Problems with the default Async logger

[Async](https://opensource.janestreet.com/async/) comes with a [logging module](https://github.com/janestreet/async_unix/blob/ecf27931acaf003cf9a9aca2626d8ddfdacab193/src/log.mli) that is really easy to use, and provides a simple interface that allows logging at a specific level and attaching some tags alongwith a message payload.

```ocaml
open! Core
open! Async

let my_cool_function user =
    Log.Global.info "This is a log message";
    Log.Global.debug ~tags:["user", User.id user] "Send confirmation email";
    send_message user
```

This produces output that looks similar to:
```
2022-09-02 11:27:54.561533-04:00 Info This is a log message
2022-09-02 11:29:14.504046-04:00 Debug Send confirmation email -- [user: 12345]
```

While easy to use the default logger does have some limitations. The log output is easy to read for humans, but it requires post-processing to transform it into a format that's easier to parse. [^2] 

Log correlation is another challenge. In synchronous blocking systems transactions are served sequentially and as a result its easy to spot that any log event occuring after a transaction starts and before a transaction ends is related to the specific transaction. However in libraries like [Async](https://opensource.janestreet.com/async/) threading is non-preemptive and a single system thread can execute any number of user-mode "threads" asynchronously. In such systems a transaction might not run to completion and instead yield control to the scheduler so a different transaction can run. This results in logs from concurrent transactions to be printed interleaved.

We can simulate multiple transactions that yield control by adding some randomized sleeps within each independant task.

```ocaml
let interleaved () =
  Log.Global.set_level `Debug;
  let task identifier =
    let%bind () = sleep_random () in
    Log.Global.debug "Starting task: %S" identifier;
    let%bind () = sleep_random () in
    Log.Global.debug "Finished first stage";
    let%bind () = sleep_random () in
    Log.Global.debug "Finished second stage";
    let%map () = sleep_random () in
    Log.Global.info "Finished task"
  in
  let%map () = task "A"
  and () = task "B"
  and () = task "C" in
  Log.Global.info "Finished all tasks"
;;
```

We might see a log output like this:

```
2022-09-02 13:45:41.775601-04:00 Debug Starting task: "C"
2022-09-02 13:45:42.121327-04:00 Debug Starting task: "B"
2022-09-02 13:45:42.223267-04:00 Debug Finished first stage
2022-09-02 13:45:42.313642-04:00 Debug Starting task: "A"
2022-09-02 13:45:42.429233-04:00 Debug Finished second stage
2022-09-02 13:45:42.775931-04:00 Debug Finished first stage
2022-09-02 13:45:42.961856-04:00 Debug Finished second stage
2022-09-02 13:45:42.969699-04:00 Debug Finished first stage
2022-09-02 13:45:43.247551-04:00 Info Finished task
2022-09-02 13:45:43.288733-04:00 Debug Finished second stage
2022-09-02 13:45:43.359040-04:00 Info Finished task
2022-09-02 13:45:43.735843-04:00 Info Finished task
2022-09-02 13:45:43.735907-04:00 Info Finished all tasks
```

The default output has details from each run of the task, but its hard to tell whether the log lines about starting and finishing the stages belongs to transaction A, B or C.


[^2]: Async supports s-expressions as a log output, but outside of the OCaml ecosystem s-expressions aren't common and most centralized log management systems don't support s-expressions.

## Better Logging configuration

We've seen some limitations of the out-of-the-box configration of Async's logging module, but Async provides an API for controlling how log messages are rendered and it can work with user-provided logging output implementations. Lets use this ability to address the two problems we talked about by implementing a machine readable output format for log messages and a system for adding unique identifiers for transactions within log messages.

### JSON formatted logs

Using centralized logging system is a fairly typical in real world deployments, as it can help to efficiently sift through the logs originating within the many separate applications running within the system. [Elasticsearch](https://www.elastic.co/observability/log-monitoring) is one such system and the example we'll use in this post. Elasticsearch can ingest logs, and provides a scalable interface for monitoring logs. It is possible to post-process application logs by parsing, transforming, and enriching logs before they get indexed by Elasticsearch, but we will instead configure Async's logger to output JSON formatted logs. JSON objects are easy to parse, and will help avoid the need for potentially brittle regex based parsing to extract data from logs.

{{< code numbered="true" >}}
module Output = struct
  let json [[[writer]]] =
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
          Writer.write_line writer ([[[Jsonaf.to_string]]] (`Assoc message)));
        Deferred.unit)
  ;;
end
{{< /code >}}

1. [Async_unix.Writer.t](https://github.com/janestreet/async_unix/blob/ecf27931acaf003cf9a9aca2626d8ddfdacab193/src/writer.mli) that acts as the sink for all log messages generated by a Logger.
2. We use [jsonaf](https://github.com/janestreet/jsonaf) for generating json payloads.

```ocaml
let json_logs () =
  let stdout = Lazy.force Writer.stdout in
  Log.Global.set_output [ Output.json stdout ];
  Log.Global.set_level `Debug;
  let task identifier =
    let%bind () = sleep_random () in
    Log.Global.debug "Starting task: %s" identifier;
    let%bind () = sleep_random () in
    Log.Global.debug "Finished first stage";
    let%bind () = sleep_random () in
    Log.Global.debug "Finished second stage";
    let%map () = sleep_random () in
    Log.Global.info "Finished task"
  in
  let%map () = task "A"
  and () = task "B"
  and () = task "C" in
  Log.Global.info "Finished all tasks"
;;
```

We might see a log output like this:

```
{"@timestamp":"2022-09-02 18:13:21.329844Z","message":"Starting task: C","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:21.711095Z","message":"Starting task: A","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:21.864161Z","message":"Starting task: B","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:21.903899Z","message":"Finished first stage","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:22.342807Z","message":"Finished first stage","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:22.408197Z","message":"Finished second stage","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:22.788932Z","message":"Finished first stage","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:22.928766Z","message":"Finished task","log.level":"Info"}
{"@timestamp":"2022-09-02 18:13:23.128315Z","message":"Finished second stage","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:23.546877Z","message":"Finished second stage","log.level":"Debug"}
{"@timestamp":"2022-09-02 18:13:24.009860Z","message":"Finished task","log.level":"Info"}
{"@timestamp":"2022-09-02 18:13:24.109893Z","message":"Finished task","log.level":"Info"}
{"@timestamp":"2022-09-02 18:13:24.109972Z","message":"Finished all tasks","log.level":"Info"}
```

### Unique identifiers for transactions

We now have JSON formatted logs that are easy to parse, but we still have the problem caused by interleaved logs as we don't have an easy way to correlate logs with specific transactions. Proper distributed log-correlation is a bigger problem that deserves its own detailed post, but we can still implement techniques to implement a fairly usable context propagation for log messages. 

A naive approach would be to manually forward a unique id to each transaction and manually forward the identifier at each callsite for a logging function. This approach is brittle as it relies on users to remember to use the unique identifier when logging something, and this needs us to re-write all functions that perform logging to also accept an additional argument that represents a unique identifier.

A more robust approach would be if every function that needed to log something could lookup a unique identifier that's currently active in its context. Blocking applications that use pre-emptive threads can rely on thread-local-storage for this usecase and maintain a stack of context ids that can be used by the logging system to determine the current active context id and automatically attach it to a log event. This approach doesn't work for user-mode threaded systems as a single thread can switch between various tasks, or systems where a task could potentially jump across threads. Async provides a solution for such context progatation that works at task level, and its naturally called [ExecutionContext](https://github.com/janestreet/async_kernel/blob/a6bd9b2074b9af3b0c3498a7327ea542909ea211/src/execution_context.mli). Every Async task runs within an excecution context, and the context object offers users to append some metadata to its local storage.

The first task is to come up with a unique identifier that we'll use to tag log messages. We could use UUIDs, but a better option might be to use a random 16 byte identifier that's compliant with the W3C recommendation for propagating distributed tracing contexts across applications. One potential implementation of this random ID generation can be seen below:

```ocaml
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
```

With the ID generation out of the way, we can now look at automatic ID context propagation for async tasks. Instead of implementing a limited solution that just works for IDs we will implement a way to propagate generic log tags. This can be used to progate other metadata in addition to the ID that could be useful to append to every log message within a transaction.

{{< code numbered="true" >}}
module Logger : sig
  include Log.Global_intf

  val with_transaction : f:(unit -> 'a Deferred.t) -> 'a Deferred.t

  val log_transform : (Log.Message.t -> Log.Message.t) option
end = struct
  [[[include Log.Make_global ()]]]

  let [[[tag_key]]] = Univ_map.Key.create ~name:"log_tags" [%sexp_of: (string * string) list]

  let merge_tags left right =
    [ left; right ]
    |> List.concat
    |> List.sort ~compare:(fun (key1, _) (key2, _) -> String.Caseless.compare key1 key2)
    |> List.remove_consecutive_duplicates
         [[[~which_to_keep:`Last]]]
         ~equal:(fun (key1, _) (key2, _) -> String.Caseless.equal key1 key2)
  ;;

  let [[[with_tags]]] tags f =
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

  let [[[log_transform]]] =
    Some
      (fun msg ->
        let open Log.Message in
        let level = level msg
        and raw_message = raw_message msg
        and tags = add_tags_if_present (tags msg)
        and time = time msg in
        create ?level ~tags ~time raw_message)
  ;;

  let [[[with_transaction]]] ~f =
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
{{< /code >}}

1. `Make_global` generates a new unique singleton logging module. It can be useful for libraries to generate a unique Logger instead of pushing content to the application's global logger (`Log.Global`)
2. Unique identifier that associates log tags within an execution context's local storage.
3. When merging the existing tags within an execution context's local storage with user provided tags, we always favor the user provided tag if there's a clash between its key and an existing key within the local storage.
4. `with_tags` runs the user provided function within an execution context where the local storage contains tag list created after merging the user provided tags with the existing tags (if any) within the call site's current execution context.
5. `log_transform` is called by Async's logging system and gives us the opportunity to transform a log message by automatically attaching log tags if some tags exist in the execution context's local storage. The transform merges the local storage's tags with any new tags provided directly at the call site of a log message.
6. `with_transaction` generates a new random transaction ID, and runs the user provided function within an execution context with a trace id tag stored in its local storage.

Example showing the use of these new logging utilities:

```ocaml
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

let main () =
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
```

We might see a log output like this:

```
{"@timestamp":"2022-09-02 19:12:48.327648Z","message":"Starting tasks","log.level":"Debug","trace.id":"a8be55ee47252520baa1dcae035d8170"}
{"@timestamp":"2022-09-02 19:12:48.481808Z","message":"Starting task: B","log.level":"Debug","trace.id":"8f70a70a2e3f49528aa04ad35208b3fb"}
{"@timestamp":"2022-09-02 19:12:48.941080Z","message":"Starting task: C","log.level":"Debug","trace.id":"ddbf3a089800458b85dea9b9f7d8d0e1"}
{"@timestamp":"2022-09-02 19:12:48.941116Z","message":"Finished first stage: B","log.level":"Debug","trace.id":"8f70a70a2e3f49528aa04ad35208b3fb"}
{"@timestamp":"2022-09-02 19:12:48.956242Z","message":"Starting task: A","log.level":"Debug","trace.id":"cf727f370192c2bb156dd18a409c9dcc"}
{"@timestamp":"2022-09-02 19:12:49.011484Z","message":"Finished first stage: A","log.level":"Debug","trace.id":"cf727f370192c2bb156dd18a409c9dcc"}
{"@timestamp":"2022-09-02 19:12:49.071507Z","message":"Finished first stage: C","log.level":"Debug","trace.id":"ddbf3a089800458b85dea9b9f7d8d0e1"}
{"@timestamp":"2022-09-02 19:12:49.251522Z","message":"Finished second stage: A","log.level":"Debug","trace.id":"cf727f370192c2bb156dd18a409c9dcc"}
{"@timestamp":"2022-09-02 19:12:49.874472Z","message":"Finished task: A","log.level":"Info","trace.id":"cf727f370192c2bb156dd18a409c9dcc"}
{"@timestamp":"2022-09-02 19:12:49.964335Z","message":"Finished second stage: C","log.level":"Debug","trace.id":"ddbf3a089800458b85dea9b9f7d8d0e1"}
{"@timestamp":"2022-09-02 19:12:49.976580Z","message":"Finished second stage: B","log.level":"Debug","trace.id":"8f70a70a2e3f49528aa04ad35208b3fb"}
{"@timestamp":"2022-09-02 19:12:50.572548Z","message":"Finished task: C","log.level":"Info","trace.id":"ddbf3a089800458b85dea9b9f7d8d0e1"}
{"@timestamp":"2022-09-02 19:12:50.717368Z","message":"Finished task: B","log.level":"Info","trace.id":"8f70a70a2e3f49528aa04ad35208b3fb"}
{"@timestamp":"2022-09-02 19:12:50.717448Z","message":"Finished all tasks","log.level":"Info","trace.id":"a8be55ee47252520baa1dcae035d8170"}
```

We added the identifier to the log message to make it easy to confirm that each unique transaction has a unique random trace id automatically attached to the log message. This shows that the actual function that performs the logging didn't need any modification. As long as we have access to Logger instance, we can use the `log_transform` implementation and get easy context propagation for log tags for free!!

## Conclusion

Voila! we now have a way to generate machine readable log messages and a lightweight method for automatic context progatation for independant async transactions.

This is all I have for now! If you like this post, or have feedback do let me know, either via [email](mailto:github@sonianurag.com) or on [github](https://github.com/anuragsoni/anuragsoni.github.io/discussions).

All the code in this post can be found on [here](https://github.com/anuragsoni/anuragsoni.github.io/blob/77227dedd4cd8617938b01b054496b75ca6b92e4/code/bin/log_example.ml). If you notice any issues let me know via [github](https://github.com/anuragsoni/anuragsoni.github.io/issues).