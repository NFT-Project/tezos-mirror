(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021-2023 Nomadic Labs <contact@nomadic-labs.com>           *)
(* Copyright (c) 2022-2023 TriliTech <contact@trili.tech>                    *)
(* Copyright (c) 2023 Functori <contact@functori.com>                        *)
(* Copyright (c) 2023 Marigold <contact@marigold.dev>                        *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

(* Testing
   -------
   Component:    Smart Optimistic Rollups
   Invocation:   dune exec tezt/tests/main.exe -- --file sc_rollup.ml
*)

open Base
open Sc_rollup_helpers

(*

   Helpers
   =======

*)

let default_wasm_pvm_revision = function
  | Protocol.Alpha -> "2.0.0-r4"
  | Protocol.Oxford -> "2.0.0-r3"
  | Protocol.Nairobi -> "2.0.0-r1"

let get_outbox_proof ?rpc_hooks ~__LOC__ sc_rollup_node ~message_index
    ~outbox_level =
  let* proof =
    Sc_rollup_node.RPC.call ?rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.outbox_proof_simple ~message_index ~outbox_level ()
  in
  match proof with
  | Some v -> return v
  | None -> failwith (Format.asprintf "Unexpected [None] at %s" __LOC__)

(* Number of levels needed to process a head as finalized. This value should
   be the same as `node_context.block_finality_time`, where `node_context` is
   the `Node_context.t` used by the rollup node. For Tenderbake, the
   block finality time is 2. *)
let block_finality_time = 2

(* List of scoru errors messages used in tests below. *)

let commit_too_recent =
  "Attempted to cement a commitment before its refutation deadline"

let disputed_commit = "Attempted to cement a disputed commitment"

let register_test ?supports ?(regression = false) ~__FILE__ ~tags ?uses ~title f
    =
  let tags = Tag.etherlink :: "sc_rollup" :: tags in
  if regression then
    Protocol.register_regression_test ?supports ~__FILE__ ~title ~tags ?uses f
  else Protocol.register_test ?supports ~__FILE__ ~title ~tags ?uses f

let get_sc_rollup_commitment_period_in_blocks client =
  let* constants = get_sc_rollup_constants client in
  return constants.commitment_period_in_blocks

let originate_sc_rollups ~kind n client =
  fold n String_map.empty (fun i addrs ->
      let alias = "rollup" ^ string_of_int i in
      let* addr = originate_sc_rollup ~alias ~kind client in
      return (String_map.add alias addr addrs))

let check_l1_block_contains ~kind ~what ?(extra = fun _ -> true) block =
  let ops = JSON.(block |-> "operations" |=> 3 |> as_list) in
  let ops_contents =
    List.map (fun op -> JSON.(op |-> "contents" |> as_list)) ops |> List.flatten
  in
  match
    List.find_all
      (fun content ->
        JSON.(content |-> "kind" |> as_string) = kind && extra content)
      ops_contents
  with
  | [] -> Test.fail "Block does not contain %s" what
  | contents ->
      List.iter
        (fun content ->
          let status =
            JSON.(
              content |-> "metadata" |-> "operation_result" |-> "status"
              |> as_string)
          in
          Check.((status = "applied") string)
            ~error_msg:(sf "%s status in block is %%L instead of %%R" what))
        contents ;
      contents

let wait_for_current_level node ?timeout sc_rollup_node =
  let* current_level = Node.get_level node in
  Sc_rollup_node.wait_for_level ?timeout sc_rollup_node current_level

let gen_keys_then_transfer_tez ?(giver = Constant.bootstrap1.alias)
    ?(amount = Tez.of_int 1_000) client n =
  let* keys, multiple_transfers_json_batch =
    let str_amount = Tez.to_string amount in
    fold n ([], []) (fun _i (keys, json_batch_dest) ->
        let* key = Client.gen_and_show_keys client in
        let json_batch_dest =
          `O
            [("destination", `String key.alias); ("amount", `String str_amount)]
          :: json_batch_dest
        in
        let keys = key :: keys in
        return (keys, json_batch_dest))
  in
  let*! () =
    Client.multiple_transfers
      ~giver
      ~json_batch:(JSON.encode_u (`A multiple_transfers_json_batch))
      ~burn_cap:(Tez.of_int 10)
      client
  in
  let* _ = Client.bake_for_and_wait client in
  return keys

let test_l1_scenario ?supports ?regression ?hooks ~kind ?boot_sector
    ?whitelist_enable ?whitelist ?commitment_period ?challenge_window ?timeout
    ?(src = Constant.bootstrap1.alias) ?rpc_external ?uses
    {variant; tags; description} scenario =
  let tags = kind :: tags in
  register_test
    ?supports
    ?regression
    ~__FILE__
    ~tags
    ?uses
    ~title:(format_title_scenario kind {variant; tags; description})
  @@ fun protocol ->
  let* tezos_node, tezos_client =
    setup_l1
      ?commitment_period
      ?challenge_window
      ?timeout
      ?whitelist_enable
      ?rpc_external
      protocol
  in
  let* sc_rollup =
    originate_sc_rollup ?hooks ~kind ?boot_sector ?whitelist ~src tezos_client
  in
  scenario protocol sc_rollup tezos_node tezos_client

let test_full_scenario ?supports ?regression ?hooks ~kind ?mode ?boot_sector
    ?commitment_period ?(parameters_ty = "string") ?challenge_window ?timeout
    ?rollup_node_name ?whitelist_enable ?whitelist ?operator ?operators
    ?(uses = fun _protocol -> []) ?rpc_external ?allow_degraded
    {variant; tags; description} scenario =
  let tags = kind :: tags in
  register_test
    ?supports
    ?regression
    ~__FILE__
    ~tags
    ~uses:(fun protocol -> Constant.octez_smart_rollup_node :: uses protocol)
    ~title:(format_title_scenario kind {variant; tags; description})
  @@ fun protocol ->
  let riscv_pvm_enable = kind = "riscv" in
  let* tezos_node, tezos_client =
    setup_l1
      ?rpc_external
      ?commitment_period
      ?challenge_window
      ?timeout
      ?whitelist_enable
      ~riscv_pvm_enable
      protocol
  in
  let operator =
    if Option.is_none operator && Option.is_none operators then
      Some Constant.bootstrap1.alias
    else operator
  in
  let* rollup_node, sc_rollup =
    setup_rollup
      ~parameters_ty
      ~kind
      ?hooks
      ?mode
      ?boot_sector
      ?rollup_node_name
      ?whitelist
      ?operator
      ?operators
      ?allow_degraded
      tezos_node
      tezos_client
  in
  scenario protocol rollup_node sc_rollup tezos_node tezos_client

(*

   Tests
   =====

*)

(* Originate a new SCORU
   ---------------------

   - Rollup addresses are fully determined by operation hashes and origination nonce.
*)
let test_origination ~kind =
  test_l1_scenario
    ~regression:true
    ~hooks
    {
      variant = None;
      tags = ["origination"];
      description = "origination of a SCORU executes without error";
    }
    ~kind
    (fun _ _ _ _ -> unit)

(* Initialize configuration
   ------------------------

   Can use CLI to initialize the rollup node config file
*)
let test_rollup_node_configuration ~kind =
  test_full_scenario
    {
      variant = None;
      tags = ["configuration"];
      description = "configuration of a smart rollup node is robust";
    }
    ~kind
  @@ fun _protocol rollup_node sc_rollup tezos_node tezos_client ->
  let* _filename = Sc_rollup_node.config_init rollup_node sc_rollup in
  let config = Sc_rollup_node.Config_file.read rollup_node in
  let _rpc_port = JSON.(config |-> "rpc-port" |> as_int) in
  let data_dir = Sc_rollup_node.data_dir rollup_node in
  Log.info "Check that config cannot be overwritten" ;
  let p = Sc_rollup_node.spawn_config_init rollup_node sc_rollup in
  let* () =
    Process.check_error
      p
      ~exit_code:1
      ~msg:(rex "Configuration file \".*\" already exists")
  in
  (* Corrupt config file manually *)
  let config_file = Sc_rollup_node.Config_file.filename rollup_node in
  let out_chan = open_out config_file in
  (try
     output_string out_chan "corrupted" ;
     close_out out_chan
   with _ -> close_out out_chan) ;
  (* Overwrite configuration *)
  Log.info "Check that config can be overwritten with --force" ;
  let* (_ : string) =
    Sc_rollup_node.config_init ~force:true rollup_node sc_rollup
  in
  let config = Sc_rollup_node.Config_file.read rollup_node in
  let rpc_port = JSON.(config |-> "rpc-port" |> as_int) in
  Check.((rpc_port = Sc_rollup_node.rpc_port rollup_node) int)
    ~error_msg:"Read %L from overwritten config but expected %R." ;
  Log.info "Check that rollup node cannot be used for annother rollup" ;
  (* Run the rollup node to initialize store and context *)
  let* () = Sc_rollup_node.run rollup_node sc_rollup [] in
  let* () = Sc_rollup_node.terminate rollup_node in
  (* Run a rollup node in the same data_dir, but for a different rollup *)
  let* other_rollup_node, other_sc_rollup =
    setup_rollup ~alias:"rollup2" ~kind tezos_node tezos_client ~data_dir
  in
  let expect_failure () =
    match Sc_rollup_node.process other_rollup_node with
    | None -> unit
    | Some p ->
        Process.check_error
          ~exit_code:1
          ~msg:(rex "This rollup node was already set up for rollup")
          p
  in
  let run_promise =
    let* () = Sc_rollup_node.run other_rollup_node other_sc_rollup [] in
    Test.fail "Node for other rollup in same dir run without errors"
  in
  Lwt.choose [run_promise; expect_failure ()]

(* Launching a rollup node
   -----------------------

   A running rollup node can be asked the address of the rollup it is
   interacting with.
*)
let test_rollup_node_running ~kind =
  test_full_scenario
    {
      variant = None;
      tags = ["running"];
      description = "the smart contract rollup node runs on correct address";
    }
    ~kind
  @@ fun _protocol rollup_node sc_rollup _tezos_node _tezos_client ->
  let* () = Sc_rollup_node.run rollup_node sc_rollup [] in
  let* sc_rollup_from_rpc =
    Sc_rollup_node.RPC.call ~rpc_hooks rollup_node
    @@ Sc_rollup_rpc.get_global_smart_rollup_address ()
  in
  if sc_rollup_from_rpc <> sc_rollup then
    failwith
      (Printf.sprintf
         "Expecting %s, got %s when we query the sc rollup node RPC address"
         sc_rollup
         sc_rollup_from_rpc)
  else
    let metrics_addr, metrics_port = Sc_rollup_node.metrics rollup_node in
    let url =
      "http://" ^ metrics_addr ^ ":" ^ string_of_int metrics_port ^ "/metrics"
    in
    let*! metrics = Curl.get_raw url in
    let regexp = Str.regexp "\\(#HELP.*\n.*#TYPE.*\n.*\\)+" in
    if not (Str.string_match regexp metrics 0) then
      Test.fail "Unable to read metrics"
    else unit

(** Genesis information and last cemented commitment at origination are correct
----------------------------------------------------------

   We can fetch the hash and level of the last cemented commitment and it's
   initially equal to the origination information.
*)
let test_rollup_get_genesis_info ~kind =
  test_l1_scenario
    {
      variant = None;
      tags = ["genesis_info"; "lcc"];
      description = "genesis info and last cemented are equal at origination";
    }
    ~kind
  @@ fun _protocol sc_rollup tezos_node tezos_client ->
  let* origination_level = Node.get_level tezos_node in
  (* Bake 10 blocks to be sure that the origination_level of rollup is different
     from the level of the head node. *)
  let* () = repeat 10 (fun () -> Client.bake_for_and_wait tezos_client) in
  let* hash, level =
    last_cemented_commitment_hash_with_level ~sc_rollup tezos_client
  in
  let* genesis_info =
    Client.RPC.call tezos_client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let genesis_hash = JSON.(genesis_info |-> "commitment_hash" |> as_string) in
  let genesis_level = JSON.(genesis_info |-> "level" |> as_int) in
  Check.((hash = genesis_hash) string ~error_msg:"expected value %L, got %R") ;
  (* The level of the last cemented commitment should correspond to the
     rollup origination level. *)
  Check.((level = origination_level) int ~error_msg:"expected value %L, got %R") ;
  Check.(
    (genesis_level = origination_level)
      int
      ~error_msg:"expected value %L, got %R") ;
  unit

(** Wait for the [sc_rollup_node_publish_execute_whitelist_update]
    event from the rollup node. *)
let wait_for_publish_execute_whitelist_update node =
  Sc_rollup_node.wait_for
    node
    "smart_rollup_node_publish_execute_whitelist_update.v0"
  @@ fun json ->
  let hash = JSON.(json |-> "hash" |> as_string) in
  let outbox_level = JSON.(json |-> "outbox_level" |> as_int) in
  let index = JSON.(json |-> "message_index" |> as_int) in
  Some (hash, outbox_level, index)

(** Wait for the [sc_rollup_node_publish_execute_whitelist_update]
    event from the rollup node. *)
let wait_for_included_successful_operation node ~operation_kind =
  Sc_rollup_node.wait_for
    node
    "smart_rollup_node_daemon_included_successful_operation.v0"
  @@ fun json ->
  if JSON.(json |-> "kind" |> as_string) = operation_kind then Some () else None

let wait_until_n_batches_are_injected rollup_node ~nb_batches =
  let nb_injected = ref 0 in
  Sc_rollup_node.wait_for rollup_node "injected_ops.v0" @@ fun _json ->
  nb_injected := !nb_injected + 1 ;
  if !nb_injected >= nb_batches then Some () else None

let send_message_batcher_aux ?rpc_hooks client sc_node msgs =
  let batched =
    Sc_rollup_node.wait_for sc_node "batched.v0" (Fun.const (Some ()))
  in
  let added_to_injector =
    Sc_rollup_node.wait_for sc_node "add_pending.v0" (Fun.const (Some ()))
  in
  let injected = wait_for_injecting_event ~tags:["add_messages"] sc_node in
  let* hashes =
    Sc_rollup_node.RPC.call sc_node ?rpc_hooks
    @@ Sc_rollup_rpc.post_local_batcher_injection ~messages:msgs
  in
  (* New head will trigger injection  *)
  let* () = Client.bake_for_and_wait client in
  (* Injector should get messages right away because the batcher is configured
     to not have minima. *)
  let* _ = batched in
  let* _ = added_to_injector in
  let* _ = injected in
  return hashes

let send_message_batcher ?rpc_hooks client sc_node msgs =
  let* hashes = send_message_batcher_aux ?rpc_hooks client sc_node msgs in
  (* Next head will include messages  *)
  let* () = Client.bake_for_and_wait client in
  return hashes

let send_messages_batcher ?rpc_hooks ?batch_size n client sc_node =
  let batches =
    List.map
      (fun i ->
        let batch_size = match batch_size with None -> i | Some v -> v in
        List.map (fun j -> Format.sprintf "%d-%d" i j) (range 1 batch_size))
      (range 1 n)
  in
  let* rhashes =
    Lwt_list.fold_left_s
      (fun acc msgs ->
        let* hashes = send_message_batcher_aux ?rpc_hooks client sc_node msgs in
        return (List.rev_append hashes acc))
      []
      batches
  in
  (* Next head will include messages of last batch *)
  let* () = Client.bake_for_and_wait client in
  return (List.rev rhashes)

(* Synchronizing the inbox in the rollup node
   ------------------------------------------

   For each new head set by the Tezos node, the rollup node retrieves
   the messages of its rollup and maintains its internal inbox in a
   persistent state stored in its data directory. This process can
   handle Tezos chain reorganization and can also catch up to ensure a
   tight synchronization between the rollup and the layer 1 chain.

   In addition, this maintenance includes the computation of a Merkle
   tree which must have the same root hash as the one stored by the
   protocol in the context.
*)
let test_rollup_node_inbox ?(extra_tags = []) ~variant scenario ~kind =
  test_full_scenario
    {
      variant = Some variant;
      tags = ["inbox"] @ extra_tags;
      description = "maintenance of inbox in the rollup node";
    }
    ~kind
  @@ fun _protocol sc_rollup_node sc_rollup node client ->
  let* () = scenario sc_rollup_node sc_rollup node client in
  let* inbox_from_sc_rollup_node =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_inbox ()
  in
  let* inbox_from_tezos_node =
    Client.RPC.call client
    @@ RPC.get_chain_block_context_smart_rollups_all_inbox ()
  in
  let tup_from_struct RPC.{old_levels_messages; level; current_messages_hash} =
    (old_levels_messages, level, current_messages_hash)
  in
  return
  @@ Check.(
       (tup_from_struct inbox_from_sc_rollup_node
       = tup_from_struct inbox_from_tezos_node)
         (tuple3 string int (option string))
         ~error_msg:"expected value %R, got %L")

let basic_scenario sc_rollup_node sc_rollup _node client =
  let num_messages = 2 in
  let expected_level =
    (* We start at level 2 and each message also bakes a block. With 2 messages being sent, we
       must end up at level 4. *)
    4
  in
  (* Here we use the legacy `run` command. *)
  let* _ = Sc_rollup_node.config_init sc_rollup_node sc_rollup in
  let* () = Sc_rollup_node.run ~legacy:true sc_rollup_node sc_rollup [] in
  let* () = send_messages num_messages client in
  let* _ =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node expected_level
  in
  unit

let sc_rollup_node_stops_scenario sc_rollup_node sc_rollup _node client =
  let num_messages = 2 in
  let expected_level =
    (* We start at level 2 and each message also bakes a block. With 2 messages being sent twice, we
       must end up at level 6. *)
    6
  in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* () = send_messages num_messages client in
  let* () = Sc_rollup_node.terminate sc_rollup_node in
  let* () = send_messages num_messages client in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* _ =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node expected_level
  in
  unit

let sc_rollup_node_disconnects_scenario sc_rollup_node sc_rollup node client =
  let num_messages = 2 in
  let* level = Node.get_level node in
  Log.info "we are at level %d" level ;
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* () = send_messages num_messages client in
  let* level = wait_for_current_level node sc_rollup_node in
  let* () = Lwt_unix.sleep 1. in
  Log.info "Terminating Tezos node" ;
  let* () = Node.terminate node in
  Log.info "Waiting before restarting Tezos node" ;
  let* () = Lwt_unix.sleep 3. in
  Log.info "Restarting Tezos node" ;
  let* () = Node.run node Node.[Connections 0; Synchronisation_threshold 0] in
  let* () = Node.wait_for_ready node in
  let* () = send_messages num_messages client in
  let* _ =
    Sc_rollup_node.wait_for_level sc_rollup_node (level + num_messages)
  in
  unit

let sc_rollup_node_handles_chain_reorg sc_rollup_node sc_rollup node client =
  let num_messages = 1 in
  let nodes_args =
    Node.[Synchronisation_threshold 0; History_mode Archive; No_bootstrap_peers]
  in
  let* node', client' = Client.init_with_node ~nodes_args `Client () in
  let* () = Client.Admin.trust_address client ~peer:node'
  and* () = Client.Admin.trust_address client' ~peer:node in
  let* () = Client.Admin.connect_address client ~peer:node' in

  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* () = send_messages num_messages client in
  (* Since we start at level 2, sending 1 message (which also bakes a block) must cause the nodes to
     observe level 3. *)
  let* _ = Node.wait_for_level node 3 in
  let* _ = Node.wait_for_level node' 3 in
  let* _ = Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node 3 in
  Log.info "Nodes are synchronized." ;

  let divergence () =
    let* identity' = Node.wait_for_identity node' in
    let* () = Client.Admin.kick_peer client ~peer:identity' in
    let* () = send_messages num_messages client in
    (* +1 block for [node] *)
    let* _ = Node.wait_for_level node 4 in

    let* () = send_messages num_messages client' in
    let* () = send_messages num_messages client' in
    (* +2 blocks for [node'] *)
    let* _ = Node.wait_for_level node' 5 in
    Log.info "Nodes are following distinct branches." ;
    unit
  in

  let trigger_reorg () =
    let* () = Client.Admin.connect_address client ~peer:node' in
    let* _ = Node.wait_for_level node 5 in
    Log.info "Nodes are synchronized again." ;
    unit
  in

  let* () = divergence () in
  let* () = trigger_reorg () in
  (* After bringing [node'] back, our SCORU node should see that there is a more attractive head at
     level 5. *)
  let* _ = Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node 5 in
  unit

let bake_levels ?hook n client =
  fold n () @@ fun i () ->
  let* () = match hook with None -> unit | Some hook -> hook i in
  Client.bake_for_and_wait client

(** Bake [at_least] levels.
    Then continues baking until an event happens.
    waiting for the rollup node to catch up to the client's level.
    Returns the event value. *)
let bake_until_event ?hook ?(at_least = 0) ?(timeout = 15.) client ?event_name
    event =
  let event_value = ref None in
  let _ =
    let* return_value = event in
    event_value := Some return_value ;
    unit
  in
  let rec bake_loop i =
    let* () = match hook with None -> unit | Some hook -> hook i in
    let* () = Client.bake_for_and_wait client in
    match !event_value with
    | Some value -> return value
    | None -> bake_loop (i + 1)
  in
  let* () = bake_levels ?hook at_least client in
  let* updated_level =
    Lwt.catch
      (fun () -> Lwt.pick [Lwt_unix.timeout timeout; bake_loop 0])
      (function
        | Lwt_unix.Timeout ->
            Test.fail
              "Timeout of %f seconds reached when waiting for event %a to \
               happens."
              timeout
              (Format.pp_print_option Format.pp_print_string)
              event_name
        | e -> raise e)
  in
  return updated_level

(** Bake [at_least] levels.
    Then continues baking until the rollup node updates the lpc,
    waiting for the rollup node to catch up to the client's level.
    Returns the level at which the lpc was updated. *)
let bake_until_lpc_updated ?hook ?at_least ?timeout client sc_rollup_node =
  let event_name = "smart_rollup_node_commitment_lpc_updated.v0" in
  let event =
    Sc_rollup_node.wait_for sc_rollup_node event_name @@ fun json ->
    JSON.(json |-> "level" |> as_int_opt)
  in
  bake_until_event ?hook ?at_least ?timeout client ~event_name event

(** helpers that send a message then bake until the rollup node
    executes an output message (whitelist_update) *)
let send_messages_then_bake_until_rollup_node_execute_output_message
    ~commitment_period ~challenge_window client rollup_node msg_list =
  let* () = send_text_messages ~hooks ~format:`Hex client msg_list in
  let* () =
    bake_until_event
      ~timeout:5.0
      ~at_least:(commitment_period + challenge_window + 1)
      client
      ~event_name:"included_successful_operation"
    @@ wait_for_included_successful_operation
         rollup_node
         ~operation_kind:"execute_outbox_message"
  and* res = wait_for_publish_execute_whitelist_update rollup_node in
  return res

let map_manager_op_from_block node ~block ~find_map_op_content =
  let* block_ops_json =
    Node.RPC.call node @@ RPC.get_chain_block_operations ~block ()
  in
  let manager_ops = JSON.(block_ops_json |=> 3 |> as_list) in
  let map_op_contents op_json =
    JSON.(op_json |-> "contents" |> as_list)
    |> List.filter_map find_map_op_content
  in
  List.map map_op_contents manager_ops |> List.flatten |> return

let wait_for_included_and_map_ops_content rollup_node node ~find_map_op_content
    =
  let* block =
    Sc_rollup_node.wait_for rollup_node "included.v0" @@ fun json ->
    Some JSON.(json |-> "block" |> as_string)
  in
  map_manager_op_from_block node ~block ~find_map_op_content

let wait_for_get_messages_and_map_ops_content rollup_node node
    ~find_map_op_content =
  let* block =
    Sc_rollup_node.wait_for
      rollup_node
      "smart_rollup_node_layer_1_get_messages.v0"
    @@ fun json -> Some JSON.(json |-> "hash" |> as_string)
  in
  map_manager_op_from_block node ~block ~find_map_op_content

let check_batcher_message_status response status =
  Check.((response = status) string)
    ~error_msg:"Status of message is %L but expected %R."

(* Rollup node batcher *)
let sc_rollup_node_batcher sc_rollup_node sc_rollup node client =
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* _level = Sc_rollup_node.wait_sync sc_rollup_node ~timeout:10. in
  Log.info "Sending one message to the batcher" ;
  let msg1 = "3 3 + out" in
  let* hashes =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.post_local_batcher_injection ~messages:[msg1]
  in
  let msg1_hash = match hashes with [h] -> h | _ -> assert false in
  let* retrieved_msg1, status_msg1 =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_batcher_queue_msg_hash ~msg_hash:msg1_hash
  in

  check_batcher_message_status status_msg1 "pending_batch" ;
  Check.((retrieved_msg1 = msg1) string)
    ~error_msg:"Message in queue is %L but injected %R." ;
  let* queue =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_batcher_queue ()
  in
  Check.((queue = [(msg1_hash, msg1)]) (list (tuple2 string string)))
    ~error_msg:"Queue is %L but should be %R." ;
  (* This block triggers injection in the injector. *)
  let injected =
    wait_for_injecting_event ~tags:["add_messages"] sc_rollup_node
  in
  let* () = Client.bake_for_and_wait client in
  let* _ = injected in
  let* _msg1, status_msg1 =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_batcher_queue_msg_hash ~msg_hash:msg1_hash
  in
  check_batcher_message_status status_msg1 "injected" ;
  (* We bake so that msg1 is included. *)
  let* () = Client.bake_for_and_wait client in
  let* _msg1, status_msg1 =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_batcher_queue_msg_hash ~msg_hash:msg1_hash
  in
  check_batcher_message_status status_msg1 "included" ;
  let* _ = wait_for_current_level node ~timeout:3. sc_rollup_node in
  Log.info "Sending multiple messages to the batcher" ;
  let msg2 =
    (* "012456789 012456789 012456789 ..." *)
    String.init 2048 (fun i ->
        let i = i mod 11 in
        if i = 10 then ' ' else Char.chr (i + 48))
  in
  let* hashes1 =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.post_local_batcher_injection
         ~messages:(List.init 9 (Fun.const msg2))
  in
  let* hashes2 =
    send_message_batcher client sc_rollup_node (List.init 9 (Fun.const msg2))
  in
  let* queue =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_batcher_queue ()
  in
  Check.((queue = []) (list (tuple2 string string)))
    ~error_msg:"Queue is %L should be %empty R." ;
  let* block = Client.RPC.call client @@ RPC.get_chain_block () in
  let contents1 =
    check_l1_block_contains
      ~kind:"smart_rollup_add_messages"
      ~what:"add messages operations"
      block
  in
  let incl_count = 0 in
  let incl_count =
    List.fold_left
      (fun count c -> count + JSON.(c |-> "message" |> as_list |> List.length))
      incl_count
      contents1
  in
  (* We bake to trigger second injection by injector. *)
  let* () = Client.bake_for_and_wait client in
  let* block = Client.RPC.call client @@ RPC.get_chain_block () in
  let contents2 =
    check_l1_block_contains
      ~kind:"smart_rollup_add_messages"
      ~what:"add messages operations"
      block
  in
  let incl_count =
    List.fold_left
      (fun count c -> count + JSON.(c |-> "message" |> as_list |> List.length))
      incl_count
      contents2
  in
  Check.((incl_count = List.length hashes1 + List.length hashes2) int)
    ~error_msg:"Only %L messages are included instead of %R." ;
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let* current_level = Node.get_level node in
  let levels =
    levels_to_commitment + init_level - current_level + block_finality_time
  in
  Log.info "Baking %d blocks for commitment of first message" levels ;
  let* _ =
    bake_until_lpc_updated ~at_least:levels ~timeout:5. client sc_rollup_node
  in
  let* _msg1, status_msg1 =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_batcher_queue_msg_hash ~msg_hash:msg1_hash
  in
  check_batcher_message_status status_msg1 "committed" ;
  unit

let rec check_can_get_between_blocks rollup_node ~first ~last =
  if last >= first then
    let* _l2_block =
      Sc_rollup_node.RPC.call ~rpc_hooks rollup_node
      @@ Sc_rollup_rpc.get_global_block_state_hash
           ~block:(string_of_int last)
           ()
    in
    let* _l2_block =
      Sc_rollup_node.RPC.call rollup_node
      @@ Sc_rollup_rpc.get_global_block ~block:(string_of_int last) ()
    in
    check_can_get_between_blocks rollup_node ~first ~last:(last - 1)
  else unit

let test_gc variant ?(tags = []) ~challenge_window ~commitment_period
    ~history_mode =
  let history_mode_str = Sc_rollup_node.string_of_history_mode history_mode in
  test_full_scenario
    {
      tags = ["gc"; history_mode_str; variant] @ tags;
      variant = Some variant;
      description =
        sf
          "garbage collection is triggered and finishes correctly (%s)"
          history_mode_str;
    }
    ~challenge_window
    ~commitment_period
  @@ fun _protocol sc_rollup_node sc_rollup node client ->
  (* GC will be invoked at every available opportunity, i.e. after every new lcc *)
  let gc_frequency = 1 in
  (* We want to bake enough blocks for the LCC to be updated and the GC
     triggered. *)
  let expected_level = 5 * challenge_window in
  (* counts number of times GC was started *)
  let gc_starts = ref 0 in
  (* counts number of times GC finished *)
  let gc_finalisations = ref 0 in
  (* to save the first level at which the GC was started *)
  let first_gc_level = ref (-1) in
  Sc_rollup_node.on_event sc_rollup_node (fun Sc_rollup_node.{name; value; _} ->
      match name with
      | "calling_gc.v0" ->
          (* On each [calling_gc] event, record the level for which it was
             called *)
          let gc_level = JSON.(value |-> "gc_level" |> as_int) in
          let head_level = JSON.(value |-> "head_level" |> as_int) in
          Log.info "Calling GC for %d at level %d" gc_level head_level ;
          if !first_gc_level = -1 then first_gc_level := head_level ;
          incr gc_starts
      | "gc_finished.v0" ->
          (* On each [gc_finished] event, increment a counter *)
          let gc_level = JSON.(value |-> "gc_level" |> as_int) in
          let head_level = JSON.(value |-> "head_level" |> as_int) in
          Log.info "Finished GC for %d at level %d" gc_level head_level ;
          incr gc_finalisations
      | _ -> ()) ;
  let* () =
    Sc_rollup_node.run
      sc_rollup_node
      sc_rollup
      [Gc_frequency gc_frequency; History_mode history_mode]
  in
  let* origination_level = Node.get_level node in
  (* We start at level 2, bake until the expected level *)
  let* () = bake_levels (expected_level - origination_level) client in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node expected_level
  in
  let expected_gc_calls =
    match history_mode with
    | Archive -> 0 (* No GC in archive mode *)
    | Full -> ((level - !first_gc_level) / commitment_period) + 1
  in
  (* Check that GC was launched at least the expected number of times,
   * at or after the expected level. This check is not an equality in order
   * to avoid flakiness due to GC being launched slightly later than
   * the expected level. *)
  Check.(
    (!gc_starts <= expected_gc_calls)
      int
      ~error_msg:"Expected at most %R GC calls, instead started %L times") ;
  assert (!gc_finalisations <= !gc_starts) ;
  (* We expect the first available level to be the one corresponding
   * to the lcc for the full mode or the genesis for archive mode *)
  let* {first_available_level; _} =
    Sc_rollup_node.RPC.call sc_rollup_node @@ Sc_rollup_rpc.get_local_gc_info ()
  in
  Log.info "First available level %d" first_available_level ;
  (* Check that RPC calls for blocks which were not GC'ed still return *)
  let* () =
    check_can_get_between_blocks
      sc_rollup_node
      ~first:first_available_level
      ~last:level
  in
  let* {code; _} =
    Sc_rollup_node.RPC.call_raw sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block
         ~block:(string_of_int (first_available_level - 1))
         ()
  in
  Check.(
    (code = 500) ~__LOC__ int ~error_msg:"Attempting to access data for level") ;

  Log.info "Checking that commitment publication data was not completely erased" ;
  let* lcc_hash, _lcc_level =
    Sc_rollup_helpers.last_cemented_commitment_hash_with_level ~sc_rollup client
  in
  let* lcc =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_commitments ~commitment_hash:lcc_hash ()
  in
  let* () =
    if lcc.published_at_level = None then
      Test.fail
        ~__LOC__
        "Commitment was published but publication info is not available \
         anymore."
    else unit
  in
  let* context_files =
    Process.run_and_read_stdout
      "ls"
      [Sc_rollup_node.data_dir sc_rollup_node ^ "/context/"]
  in
  let last_suffix =
    String.split_on_char '\n' context_files
    |> List.filter_map (fun s -> s =~* rex "store\\.(\\d+)\\.suffix")
    |> List.rev |> List.hd
  in
  let nb_suffix = int_of_string last_suffix in
  let max_nb_split =
    match history_mode with
    | Archive -> 0
    | _ -> (level - origination_level + challenge_window - 1) / challenge_window
  in
  Check.((nb_suffix <= max_nb_split) int)
    ~error_msg:"Expected at most %R context suffix files, instead got %L" ;
  unit

(* Testing that snapshots can be exported correctly for a running node, and that
   they can be used to bootstrap a blank or existing rollup node.
   - we run two rollup nodes but stop the second one at some point
   - after a while we create a snapshot from the first rollup node
   - we import the snapshot in the second and a fresh rollup node
   - we ensure they are all synchronized
   - we also try to import invalid snapshots to make sure they are rejected. *)
let test_snapshots ~kind ~challenge_window ~commitment_period ~history_mode =
  let history_mode_str = Sc_rollup_node.string_of_history_mode history_mode in
  test_full_scenario
    {
      tags = ["snapshot"; history_mode_str];
      variant = None;
      description =
        sf "snapshot can be exported and checked (%s)" history_mode_str;
    }
    ~kind
    ~challenge_window
    ~commitment_period
  @@ fun _protocol sc_rollup_node sc_rollup node client ->
  (* Originate another rollup for sanity checks *)
  let* other_rollup = originate_sc_rollup ~alias:"other_rollup" ~kind client in
  (* We want to produce snapshots for rollup node which have cemented
     commitments *)
  let* level = Node.get_level node in
  let level_snapshot = level + (2 * challenge_window) in
  (* We want to build an L2 chain that goes beyond the snapshots (and has
     additional commitments). *)
  let total_blocks = level_snapshot + (4 * commitment_period) in
  let stop_rollup_node_2_levels = challenge_window + 2 in
  let* () =
    Sc_rollup_node.run sc_rollup_node sc_rollup [History_mode history_mode]
  in
  (* We run the other nodes in mode observer because we only care if they can
     catch up. *)
  let rollup_node_2 =
    Sc_rollup_node.create Observer node ~base_dir:(Client.base_dir client)
  in
  let rollup_node_3 =
    Sc_rollup_node.create Observer node ~base_dir:(Client.base_dir client)
  in
  let rollup_node_4 =
    Sc_rollup_node.create Observer node ~base_dir:(Client.base_dir client)
  in
  let* () =
    Sc_rollup_node.run rollup_node_2 sc_rollup [History_mode history_mode]
  in
  let* () =
    Sc_rollup_node.run rollup_node_4 other_rollup [History_mode history_mode]
  in
  let rollup_node_processing =
    let* () = bake_levels stop_rollup_node_2_levels client in
    Log.info "Stopping rollup node 2 before snapshot is made." ;
    let* () = Sc_rollup_node.terminate rollup_node_2 in
    let* () = Sc_rollup_node.terminate rollup_node_4 in
    let* () = bake_levels (total_blocks - stop_rollup_node_2_levels) client in
    let* (_ : int) = Sc_rollup_node.wait_sync sc_rollup_node ~timeout:3. in
    unit
  in
  let* (_ : int) =
    Sc_rollup_node.wait_for_level sc_rollup_node level_snapshot
  in
  let dir = Tezt.Temp.dir "snapshots" in
  let dir_on_the_fly = Tezt.Temp.dir "snapshots_on_the_fly" in
  let* snapshot_file =
    Sc_rollup_node.export_snapshot sc_rollup_node dir |> Runnable.run
  and* snapshot_file_on_the_fly =
    Sc_rollup_node.export_snapshot
      ~compress_on_the_fly:true
      sc_rollup_node
      dir_on_the_fly
    |> Runnable.run
  in
  Log.info "Checking if uncompressed snapshot files are identical." ;
  (* Uncompress snapshots *)
  let* () = Process.run "cp" [snapshot_file; snapshot_file ^ ".raw.gz"] in
  let* () =
    Process.run
      "cp"
      [snapshot_file_on_the_fly; snapshot_file_on_the_fly ^ ".raw.gz"]
  in
  let* () = Process.run "gzip" ["-d"; snapshot_file ^ ".raw.gz"] in
  let* () = Process.run "gzip" ["-d"; snapshot_file_on_the_fly ^ ".raw.gz"] in
  (* Compare uncompressed snapshots *)
  let* () =
    Process.run
      "cmp"
      [snapshot_file ^ ".raw"; snapshot_file_on_the_fly ^ ".raw"]
  in
  let* exists = Lwt_unix.file_exists snapshot_file in
  if not exists then
    Test.fail ~__LOC__ "Snapshot file %s does not exist" snapshot_file ;
  let* () = rollup_node_processing in
  Log.info "Try importing snapshot for wrong rollup." ;
  let*? process_other =
    Sc_rollup_node.import_snapshot ~force:true rollup_node_4 ~snapshot_file
  in
  let* () =
    Process.check_error
      ~msg:(rex "The existing rollup node is for")
      process_other
  in
  Log.info "Importing snapshot in empty rollup node." ;
  let*! () = Sc_rollup_node.import_snapshot rollup_node_3 ~snapshot_file in
  (* rollup_node_2 was stopped before so it has data but is late with respect to
     sc_rollup_node. *)
  Log.info "Try importing snapshot in already populated rollup node." ;
  let*? populated =
    Sc_rollup_node.import_snapshot rollup_node_2 ~snapshot_file
  in
  let* () = Process.check_error ~msg:(rex "is already populated") populated in
  Log.info "Importing snapshot in late rollup node." ;
  let*! () =
    Sc_rollup_node.import_snapshot ~force:true rollup_node_2 ~snapshot_file
  in
  Log.info "Running rollup nodes with snapshots until they catch up." ;
  let* () =
    Sc_rollup_node.run rollup_node_2 sc_rollup [History_mode history_mode]
  and* () =
    Sc_rollup_node.run rollup_node_3 sc_rollup [History_mode history_mode]
  in
  let* _ = Sc_rollup_node.wait_sync ~timeout:60. rollup_node_2
  and* _ = Sc_rollup_node.wait_sync ~timeout:60. rollup_node_3 in
  Log.info "Try importing outdated snapshot." ;
  let* () = Sc_rollup_node.terminate rollup_node_2 in
  let*? outdated =
    Sc_rollup_node.import_snapshot ~force:true rollup_node_2 ~snapshot_file
  in
  let* () =
    Process.check_error
      ~msg:(rex "The rollup node is already at level")
      outdated
  in
  Log.info "Bake until next commitment." ;
  let* () =
    let event_name = "smart_rollup_node_new_commitment.v0" in
    bake_until_event client ~event_name
    @@ Sc_rollup_node.wait_for sc_rollup_node event_name (Fun.const (Some ()))
  in
  let* _ = Sc_rollup_node.wait_sync ~timeout:30.0 sc_rollup_node in
  let*! snapshot_file = Sc_rollup_node.export_snapshot sc_rollup_node dir in
  (* The rollup node should not have published its commitment yet *)
  Log.info "Try importing snapshot without published commitment." ;
  Log.info "Try importing outdated snapshot." ;
  let* () = Sc_rollup_node.terminate rollup_node_2 in
  let*? unpublished =
    Sc_rollup_node.import_snapshot ~force:true rollup_node_2 ~snapshot_file
  in
  let* () =
    Process.check_error
      ~msg:(rex "Last commitment of snapshot is not published on L1.")
      unpublished
  in
  unit

(* One can retrieve the list of originated SCORUs.
   -----------------------------------------------
*)

let test_rollup_list ~kind =
  register_test
    ~__FILE__
    ~tags:["sc_rollup"; "list"]
    ~title:"list originated rollups"
  @@ fun protocol ->
  let* _node, client = setup_l1 protocol in
  let* rollups =
    Client.RPC.call client @@ RPC.get_chain_block_context_smart_rollups_all ()
  in
  let () =
    match rollups with
    | _ :: _ ->
        failwith "Expected initial list of originated SCORUs to be empty"
    | [] -> ()
  in
  let* scoru_addresses = originate_sc_rollups ~kind 10 client in
  let scoru_addresses =
    String_map.fold
      (fun _alias addr addrs -> String_set.add addr addrs)
      scoru_addresses
      String_set.empty
  in
  let* rollups =
    Client.RPC.call client @@ RPC.get_chain_block_context_smart_rollups_all ()
  in
  let rollups = String_set.of_list rollups in
  Check.(
    (rollups = scoru_addresses)
      (comparable_module (module String_set))
      ~error_msg:"%L %R") ;
  unit

let test_client_wallet ~kind =
  register_test
    ~__FILE__
    ~tags:["sc_rollup"; "wallet"; "client"]
    ~title:"test the client wallet for smart rollup"
  @@ fun protocol ->
  let* _node, client = setup_l1 protocol in
  let* expected_alias_addresses = originate_sc_rollups ~kind 10 client in
  let*! found_alias_addresses =
    Client.Sc_rollup.list_known_smart_rollups client
  in
  let found_alias_addresses =
    List.fold_left
      (fun addrs (alias, addr) -> String_map.add alias addr addrs)
      String_map.empty
      found_alias_addresses
  in
  String_map.iter
    (fun alias addr ->
      if not (String_map.mem alias found_alias_addresses) then
        Test.fail "alias %s does not exist in the wallet." alias
      else
        let found_addr = String_map.find alias found_alias_addresses in
        Check.((found_addr = addr) string ~error_msg:"%L %R"))
    expected_alias_addresses ;
  let*? process = Client.Sc_rollup.forget_all_smart_rollups client in
  let* output_err =
    Process.check_and_read_stderr ~expect_failure:true process
  in
  Check.(
    (output_err =~ rex ".*this can only be used with option --force.*")
      ~error_msg:"Expected output %L to match expression %R.") ;
  let*! () = Client.Sc_rollup.forget_all_smart_rollups ~force:true client in
  let*! found_alias_addresses =
    Client.Sc_rollup.list_known_smart_rollups client
  in
  Check.(
    (found_alias_addresses = [])
      (list (tuple2 string string))
      ~error_msg:"Expected output %L to be empty.") ;
  let expected_address = String_map.find "rollup1" expected_alias_addresses in
  let alias = "my_rollup" in
  let*! () =
    Client.Sc_rollup.remember_smart_rollup
      client
      ~alias
      ~address:expected_address
  in
  let*! found_address =
    Client.Sc_rollup.show_known_smart_rollup ~alias client
  in
  Check.(
    (String.trim found_address = expected_address)
      string
      ~error_msg:"Expected address %L to be %R.") ;
  unit

(* Make sure the rollup node boots into the initial state.
   -------------------------------------------------------

   When a rollup node starts, we want to make sure that in the absence of
   messages it will boot into the initial state.
*)
let test_rollup_node_boots_into_initial_state ?supports ~kind =
  test_full_scenario
    ?supports
    {
      variant = None;
      tags = ["bootstrap"];
      description = "rollup node boots into the initial state";
    }
    ~kind
  @@ fun _protocol sc_rollup_node sc_rollup _node client ->
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* ticks =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_total_ticks ()
  in
  Check.(ticks = 0)
    Check.int
    ~error_msg:"Unexpected initial tick count (%L = %R)" ;
  let* status =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_status ()
  in
  let expected_status =
    match kind with
    | "arith" -> "Halted"
    | "wasm_2_0_0" -> "Waiting for input message"
    | "riscv" -> "riscv_dummy_status"
    | _ -> raise (Invalid_argument kind)
  in
  Check.(status = expected_status)
    Check.string
    ~error_msg:"Unexpected PVM status (%L = %R)" ;
  unit

let test_rollup_node_advances_pvm_state ?regression ~title ?boot_sector
    ~internal ~kind =
  test_full_scenario
    ?regression
    ~hooks
    {
      variant = Some (if internal then "internal" else "external");
      tags = ["pvm"];
      description = title;
    }
    ?boot_sector
    ~parameters_ty:"bytes"
    ~kind
  @@ fun protocol sc_rollup_node sc_rollup _tezos_node client ->
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* _ = Sc_rollup_node.wait_sync ~timeout:30. sc_rollup_node in
  let* forwarder =
    if not internal then return None
    else
      let* contract_id = originate_forward_smart_contract client protocol in
      let* _ = Sc_rollup_node.wait_sync ~timeout:30. sc_rollup_node in
      return (Some contract_id)
  in
  (* Called with monotonically increasing [i] *)
  let test_message i =
    let* prev_state_hash =
      Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
      @@ Sc_rollup_rpc.get_global_block_state_hash ()
    in
    let* prev_ticks =
      Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
      @@ Sc_rollup_rpc.get_global_block_total_ticks ()
    in
    let message = sf "%d %d + value" i ((i + 2) * 2) in
    let* () =
      match forwarder with
      | None ->
          (* External message *)
          send_message ~hooks client (sf "[%S]" message)
      | Some forwarder ->
          (* Internal message through forwarder *)
          let message = hex_encode message in
          let* () =
            Client.transfer
              client
              ~amount:Tez.zero
              ~giver:Constant.bootstrap1.alias
              ~receiver:forwarder
              ~arg:(sf "Pair 0x%s %S" message sc_rollup)
          in
          Client.bake_for_and_wait client
    in
    let* _ = Sc_rollup_node.wait_sync ~timeout:30. sc_rollup_node in

    (* specific per kind PVM checks *)
    let* () =
      match kind with
      | "arith" ->
          let* encoded_value =
            Sc_rollup_node.RPC.call sc_rollup_node ~rpc_hooks
            @@ Sc_rollup_rpc.get_global_block_state ~key:"vars/value" ()
          in
          let value =
            match Data_encoding.(Binary.of_bytes int31) @@ encoded_value with
            | Error error ->
                failwith
                  (Format.asprintf
                     "The arithmetic PVM has an unexpected state: %a"
                     Data_encoding.Binary.pp_read_error
                     error)
            | Ok x -> x
          in
          Check.(
            (value = i + ((i + 2) * 2))
              int
              ~error_msg:"Invalid value in rollup state (%L <> %R)") ;
          unit
      | "wasm_2_0_0" ->
          (* TODO: https://gitlab.com/tezos/tezos/-/issues/3729

              Add an appropriate check for various test kernels

                computation.wasm               - Gets into eval state
                no_parse_random.wasm           - Stuck state due to parse error
                no_parse_bad_fingerprint.wasm  - Stuck state due to parse error
          *)
          unit
      | _otherwise -> raise (Invalid_argument kind)
    in

    let* state_hash =
      Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
      @@ Sc_rollup_rpc.get_global_block_state_hash ()
    in
    Check.(state_hash <> prev_state_hash)
      Check.string
      ~error_msg:"State hash has not changed (%L <> %R)" ;
    let* ticks =
      Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
      @@ Sc_rollup_rpc.get_global_block_total_ticks ()
    in
    Check.(ticks >= prev_ticks)
      Check.int
      ~error_msg:"Tick counter did not advance (%L >= %R)" ;

    unit
  in
  let* () = Lwt_list.iter_s test_message (range 1 10) in

  unit

let test_rollup_node_run_with_kernel ~kind ~kernel_name ~internal =
  test_rollup_node_advances_pvm_state
    ~title:(Format.sprintf "runs with kernel - %s" kernel_name)
    ~boot_sector:(read_kernel kernel_name)
    ~internal
    ~kind

(* Ensure the PVM is transitioning upon incoming messages.
      -------------------------------------------------------

      When the rollup node receives messages, we like to see evidence that the PVM
      has advanced.

      Specifically [test_rollup_node_advances_pvm_state ?boot_sector protocols ~kind]

      * Originates a SCORU of [kind]
      * Originates a L1 contract to send internal messages from
      * Sends internal or external messages to the rollup

   After each a PVM kind-specific test is run, asserting the validity of the new state.
*)
let test_rollup_node_advances_pvm_state ~kind ?boot_sector ~internal =
  test_rollup_node_advances_pvm_state
    ~regression:true
    ~title:"node advances PVM state with messages"
    ?boot_sector
    ~internal
    ~kind

(* Ensure that commitments are stored and published properly.
   ----------------------------------------------------------

   Every 20 level, a commitment is computed and stored by the
   rollup node. The rollup node will also publish previously
   computed commitments on the layer1, in a first in first out
   fashion. To ensure that commitments are robust to chain
   reorganisations, only finalized block are processed when
   trying to publish a commitment.
*)

let eq_commitment_typ =
  Check.equalable
    (fun ppf (c : RPC.smart_rollup_commitment) ->
      Format.fprintf
        ppf
        "@[<hov 2>{ predecessor: %s,@,\
         state: %s,@,\
         inbox level: %d,@,\
         ticks: %d }@]"
        c.predecessor
        c.compressed_state
        c.inbox_level
        c.number_of_ticks)
    ( = )

let check_commitment_eq (commitment, name) (expected_commitment, exp_name) =
  Check.((commitment = expected_commitment) eq_commitment_typ)
    ~error_msg:
      (sf
         "Commitment %s differs from the one %s.\n%s: %%L\n%s: %%R"
         name
         exp_name
         (String.capitalize_ascii name)
         (String.capitalize_ascii exp_name))

let tezos_client_get_commitment client sc_rollup commitment_hash =
  let* commitment_opt =
    Client.RPC.call client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_commitment
         ~sc_rollup
         ~hash:commitment_hash
         ()
  in
  return commitment_opt

let check_published_commitment_in_l1 ?(force_new_level = true) sc_rollup client
    (published_commitment : Sc_rollup_rpc.commitment_info) =
  let* () =
    if force_new_level then
      (* Triggers injection into the L1 context *)
      bake_levels 1 client
    else unit
  in
  let* commitment_in_l1 =
    tezos_client_get_commitment
      client
      sc_rollup
      published_commitment.commitment_and_hash.hash
  in
  let published_commitment =
    published_commitment.commitment_and_hash.commitment
  in
  check_commitment_eq
    (commitment_in_l1, "in L1")
    (published_commitment, "published") ;
  unit

let test_commitment_scenario ?supports ?commitment_period ?challenge_window
    ?(extra_tags = []) ~variant =
  test_full_scenario
    ?supports
    ?commitment_period
    ?challenge_window
    {
      tags = ["commitment"] @ extra_tags;
      variant = Some variant;
      description = "rollup node - correct handling of commitments";
    }

let bake_levels ?hook n client =
  fold n () @@ fun i () ->
  let* () = match hook with None -> unit | Some hook -> hook i in
  Client.bake_for_and_wait client

let commitment_stored _protocol sc_rollup_node sc_rollup _node client =
  (* The rollup is originated at level `init_level`, and it requires
     `sc_rollup_commitment_period_in_blocks` levels to store a commitment.
     There is also a delay of `block_finality_time` before storing a
     commitment, to avoid including wrong commitments due to chain
     reorganisations. Therefore the commitment will be stored and published
     when the [Commitment] module processes the block at level
     `init_level + sc_rollup_commitment_period_in_blocks +
     levels_to_finalise`.
  *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in

  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* () =
    (* at init_level + i we publish i messages, therefore at level
       init_level + i a total of 1+..+i = (i*(i+1))/2 messages will have been
       sent.
    *)
    send_messages levels_to_commitment client
  in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + levels_to_commitment)
  in
  (* Bake [block_finality_time] additional levels to ensure that block number
     [init_level + sc_rollup_commitment_period_in_blocks] is
     processed by the rollup node as finalized. *)
  let* () = bake_levels block_finality_time client in
  let* {
         commitment = {inbox_level = stored_inbox_level; _} as stored_commitment;
         hash = _;
       } =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  Check.(stored_inbox_level = levels_to_commitment + init_level)
    Check.int
    ~error_msg:
      "Commitment has been stored at a level different than expected (%L = %R)" ;
  let* _level = bake_until_lpc_updated client sc_rollup_node in
  let* published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  check_commitment_eq
    (stored_commitment, "stored")
    (published_commitment.commitment_and_hash.commitment, "published") ;
  check_published_commitment_in_l1 sc_rollup client published_commitment

let mode_publish mode publishes _protocol sc_rollup_node sc_rollup node client =
  let nodes_args =
    Node.[Synchronisation_threshold 0; History_mode Archive; No_bootstrap_peers]
  in
  let* node', client' = Client.init_with_node ~nodes_args `Client () in
  let* () = Client.Admin.trust_address client ~peer:node'
  and* () = Client.Admin.trust_address client' ~peer:node in
  let* () = Client.Admin.connect_address client ~peer:node' in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let* () = send_messages levels_to_commitment client in
  let* level = Node.get_level node in
  let* _ = Sc_rollup_node.wait_for_level sc_rollup_node level in
  Log.info "Starting other rollup node." ;
  let purposes = [Sc_rollup_node.Operating; Cementing; Batching] in
  let operators =
    List.mapi
      (fun i purpose ->
        (purpose, Constant.[|bootstrap3; bootstrap5; bootstrap4|].(i).alias))
      purposes
  in
  let sc_rollup_other_node =
    (* Other rollup node *)
    Sc_rollup_node.create
      mode
      node'
      ~base_dir:(Client.base_dir client')
      ~operators
      ~default_operator:Constant.bootstrap3.alias
  in
  let* () = Sc_rollup_node.run sc_rollup_other_node sc_rollup [] in
  let* _level = Sc_rollup_node.wait_for_level sc_rollup_other_node level in
  Log.info "Other rollup node synchronized." ;
  let* () = send_messages levels_to_commitment client in
  let* level = Node.get_level node in
  let* _ = Sc_rollup_node.wait_for_level sc_rollup_node level
  and* _ = Sc_rollup_node.wait_for_level sc_rollup_other_node level in
  Log.info "Both rollup nodes have reached level %d." level ;
  let* state_hash =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ()
  in
  let* state_hash_other =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_other_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ()
  in
  Check.((state_hash = state_hash_other) string)
    ~error_msg:
      "State hash of other rollup node is %R but the first rollup node has %L" ;
  let* {body = published_commitment; _} =
    Sc_rollup_node.RPC.call_json sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  let* {body = other_published_commitment; _} =
    Sc_rollup_node.RPC.call_json sc_rollup_other_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  if JSON.is_null published_commitment then
    Test.fail "Operator has not published a commitment but should have." ;
  if JSON.is_null other_published_commitment = publishes then
    Test.fail
      "Other has%s published a commitment but should%s."
      (if publishes then " not" else "")
      (if publishes then " have" else " never do so") ;
  unit

let commitment_not_published_if_non_final _protocol sc_rollup_node sc_rollup
    _node client =
  (* The rollup is originated at level `init_level`, and it requires
     `sc_rollup_commitment_period_in_blocks` levels to store a commitment.
     There is also a delay of `block_finality_time` before publishing a
     commitment, to avoid including wrong commitments due to chain
     reorganisations. Therefore the commitment will be published
     when the [Commitment] module processes the block at level
     `init_level + sc_rollup_commitment_period_in_blocks +
     levels_to_finalise`. At the level before, the commitment will be
     neither stored but not published.
  *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in

  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let levels_to_finalize = block_finality_time - 1 in
  let store_commitment_level = init_level + levels_to_commitment in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* () = send_messages levels_to_commitment client in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      store_commitment_level
  in
  let* () = bake_levels levels_to_finalize client in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (store_commitment_level + levels_to_finalize)
  in
  let* {commitment = {inbox_level = stored_inbox_level; _}; hash = _} =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  Check.(stored_inbox_level = store_commitment_level)
    Check.int
    ~error_msg:
      "Commitment has been stored at a level different than expected (%L = %R)" ;
  let* {body = commitment_json; _} =
    Sc_rollup_node.RPC.call_json sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  Check.(JSON.is_null commitment_json = true)
    Check.bool
    ~error_msg:"No commitment published has been found by the rollup node" ;
  unit

let commitments_messages_reset kind _protocol sc_rollup_node sc_rollup _node
    client =
  (* For `sc_rollup_commitment_period_in_blocks` levels after the sc rollup
     origination, i messages are sent to the rollup, for a total of
     `sc_rollup_commitment_period_in_blocks *
     (sc_rollup_commitment_period_in_blocks + 1)/2` messages. These will be
     the number of messages in the first commitment published by the rollup
     node. Then, for other `sc_rollup_commitment_period_in_blocks` levels,
     no messages are sent to the sc-rollup address. The second commitment
     published by the sc-rollup node will contain 0 messages. Finally,
     `block_finality_time` empty levels are baked which ensures that two
     commitments are stored and published by the rollup node.
  *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in

  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* () =
    (* At init_level + i we publish i messages, therefore at level
       init_level + 20 a total of 1+..+20 = (20*21)/2 = 210 messages
       will have been sent.
    *)
    send_messages levels_to_commitment client
  in
  (* Bake other `sc_rollup_commitment_period_in_blocks +
     block_finality_time` levels with no messages. The first
     `sc_rollup_commitment_period_in_blocks` levels contribute to the second
     commitment stored by the rollup node. The last `block_finality_time`
     levels ensure that the second commitment is stored and published by the
     rollup node.
  *)
  let* () = bake_levels (levels_to_commitment + block_finality_time) client in
  let* {
         commitment =
           {
             inbox_level = stored_inbox_level;
             number_of_ticks = stored_number_of_ticks;
             _;
           } as stored_commitment;
         hash = _;
       } =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  Check.(stored_inbox_level = init_level + (2 * levels_to_commitment))
    Check.int
    ~error_msg:
      "Commitment has been stored at a level different than expected (%L = %R)" ;
  Log.info "levels_to_commitment: %d" levels_to_commitment ;
  (let expected =
     match kind with
     | "arith" -> 3 * levels_to_commitment
     | "wasm_2_0_0" ->
         4
         (* one snapshot for collecting, two snapshots for SOL,
            Info_per_level and EOL *)
         * 11_000_000_000 (* number of ticks in a snapshots *)
         * levels_to_commitment (* number of inboxes *)
     | _ -> failwith "incorrect kind"
   in
   Check.(stored_number_of_ticks = expected)
     Check.int
     ~error_msg:
       "Number of ticks processed by commitment is different from the number \
        of ticks expected (%L = %R)") ;
  let* _level = bake_until_lpc_updated client sc_rollup_node in
  let* published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  check_commitment_eq
    (stored_commitment, "stored")
    (published_commitment.commitment_and_hash.commitment, "published") ;
  check_published_commitment_in_l1 sc_rollup client published_commitment

let commitment_stored_robust_to_failures _protocol sc_rollup_node sc_rollup node
    client =
  (* This test uses two rollup nodes for the same rollup, tracking the same L1 node.
     Both nodes process heads from the L1. However, the second node is stopped
     one level before publishing a commitment, and then is restarted.
     We should not observe any difference in the commitments stored by the
     two rollup nodes.
  *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in

  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let bootstrap2_key = Constant.bootstrap2.public_key_hash in
  let* client' = Client.init ?endpoint:(Some (Node node)) () in
  let sc_rollup_node' =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client')
      ~default_operator:bootstrap2_key
  in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* () = Sc_rollup_node.run sc_rollup_node' sc_rollup [] in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* () =
    (* at init_level + i we publish i messages, therefore at level
       init_level + i a total of 1+..+i = (i*(i+1))/2 messages will have been
       sent.
    *)
    send_messages levels_to_commitment client
  in
  (* The line below works as long as we have a block finality time which is strictly positive,
     which is a safe assumption. *)
  let* () = bake_levels (block_finality_time - 1) client in
  let* level_before_storing_commitment =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + levels_to_commitment + block_finality_time - 1)
  in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node'
      level_before_storing_commitment
  in
  let* () = Sc_rollup_node.terminate sc_rollup_node' in
  let* () = Sc_rollup_node.run sc_rollup_node' sc_rollup [] in
  let* () = Client.bake_for_and_wait client in
  let* () = Sc_rollup_node.terminate sc_rollup_node' in
  let* () = Client.bake_for_and_wait client in
  let* () = Sc_rollup_node.run sc_rollup_node' sc_rollup [] in
  let* level_commitment_is_stored =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (level_before_storing_commitment + 1)
  in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node'
      level_commitment_is_stored
  in
  let* {commitment = stored_commitment; hash = _} =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  let* {commitment = stored_commitment'; hash = _} =
    Sc_rollup_node.RPC.call sc_rollup_node'
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  check_commitment_eq
    (stored_commitment, "stored in first node")
    (stored_commitment', "stored in second node") ;
  unit

let commitments_reorgs ~switch_l1_node ~kind _protocol sc_rollup_node sc_rollup
    node client =
  (* No messages are published after origination, for
     `sc_rollup_commitment_period_in_blocks - 1` levels. Then a divergence
     occurs:  in the first branch one message is published for
     `block_finality_time - 1` blocks. In the second branch no messages are
     published for `block_finality_time` blocks. The second branch is
     the more attractive one, and will be chosen when a reorganisation occurs.
     One more level is baked to ensure that the rollup node stores and
     publishes the commitment. The final commitment should have
     no messages and no ticks.
  *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in

  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client
  in
  let num_empty_blocks = block_finality_time in
  let num_messages = 1 in
  let nodes_args =
    Node.[Synchronisation_threshold 0; History_mode Archive; No_bootstrap_peers]
  in
  let* node', client' = Client.init_with_node ~nodes_args `Client () in
  let* () = Client.Admin.trust_address client ~peer:node'
  and* () = Client.Admin.trust_address client' ~peer:node in
  let* () = Client.Admin.connect_address client ~peer:node' in

  let* () =
    Sc_rollup_node.run sc_rollup_node ~event_level:`Debug sc_rollup []
  in
  (* We bake `sc_rollup_commitment_period_in_blocks - 1` levels, which
     should cause both nodes to observe level
     `sc_rollup_commitment_period_in_blocks + init_level - 1 . *)
  let* () = bake_levels (levels_to_commitment - 1) client in
  let* _ = Node.wait_for_level node (init_level + levels_to_commitment - 1) in
  let* _ = Node.wait_for_level node' (init_level + levels_to_commitment - 1) in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + levels_to_commitment - 1)
  in
  Log.info "Nodes are synchronized." ;

  let divergence () =
    let* identity' = Node.wait_for_identity node' in
    let* () = Client.Admin.kick_peer client ~peer:identity' in
    let* () = send_messages num_messages client in
    (* `block_finality_time - 1` blocks with message for [node] *)
    let* _ =
      Node.wait_for_level
        node
        (init_level + levels_to_commitment - 1 + num_messages)
    in

    let* () = bake_levels num_empty_blocks client' in
    (* `block_finality_time` blocks with no messages for [node'] *)
    let* _ =
      Node.wait_for_level
        node'
        (init_level + levels_to_commitment - 1 + num_empty_blocks)
    in
    Log.info "Nodes are following distinct branches." ;
    unit
  in

  let trigger_reorg () =
    let* () = Client.Admin.connect_address client ~peer:node' in
    let* _ =
      Node.wait_for_level
        node
        (init_level + levels_to_commitment - 1 + num_empty_blocks)
    in
    Log.info "Nodes are synchronized again." ;
    unit
  in

  let* () = divergence () in
  let* client =
    if switch_l1_node then (
      (* Switch the L1 node of a rollup node so that reverted blocks are not *)
      (* available in the new L1 node. *)
      Log.info "Changing L1 node for rollup node" ;
      let* () =
        Sc_rollup_node.change_node_and_restart
          ~event_level:`Debug
          sc_rollup_node
          sc_rollup
          node'
      in
      return client')
    else
      let* () = trigger_reorg () in
      return client
  in
  (* After triggering a reorganisation the node should see that there is a more
     attractive head at level `init_level +
     sc_rollup_commitment_period_in_blocks + block_finality_time - 1`.
  *)
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + levels_to_commitment - 1 + num_empty_blocks)
  in
  (* exactly one level left to finalize the commitment in the node. *)
  let* () = bake_levels (block_finality_time - num_empty_blocks + 1) client in
  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + levels_to_commitment + block_finality_time)
  in
  let* {
         commitment =
           {
             inbox_level = stored_inbox_level;
             number_of_ticks = stored_number_of_ticks;
             _;
           } as stored_commitment;
         hash = _;
       } =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  Check.(stored_inbox_level = init_level + levels_to_commitment)
    Check.int
    ~error_msg:
      "Commitment has been stored at a level different than expected (%L = %R)" ;
  let () = Log.info "init_level: %d" init_level in
  (let expected_number_of_ticks =
     match kind with
     | "arith" ->
         1 (* boot sector *) + 1 (* metadata *) + (3 * levels_to_commitment)
         (* input ticks *)
     | "wasm_2_0_0" ->
         (* Number of ticks per snapshot,
            see Lib_scoru_wasm.Constants.wasm_max_tick *)
         let snapshot_ticks = 11_000_000_000 in
         snapshot_ticks * 4
         (* 1 snapshot for collecting messages, 3 snapshots for SOL,
            Info_per_level and SOL *) * levels_to_commitment
         (* Number of inbox that are actually processed process *)
     | _ -> assert false
   in
   Check.(stored_number_of_ticks = expected_number_of_ticks)
     Check.int
     ~error_msg:
       "Number of ticks processed by commitment is different from the number \
        of ticks expected (%L = %R)") ;
  let* _ = bake_until_lpc_updated client sc_rollup_node in
  let* published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  check_commitment_eq
    (stored_commitment, "stored")
    (published_commitment.commitment_and_hash.commitment, "published") ;
  check_published_commitment_in_l1 sc_rollup client published_commitment

(* This test simulate a reorganisation where a block is reproposed, and ensures
   that the correct commitment is published. *)
let commitments_reproposal _protocol sc_rollup_node sc_rollup node1 client1 =
  let* genesis_info =
    Client.RPC.call ~hooks client1
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let* levels_to_commitment =
    get_sc_rollup_commitment_period_in_blocks client1
  in
  let nodes_args =
    Node.[Synchronisation_threshold 0; History_mode Archive; No_bootstrap_peers]
  in
  let* node2, client2 = Client.init_with_node ~nodes_args `Client () in
  let* () = Client.Admin.trust_address client1 ~peer:node2
  and* () = Client.Admin.trust_address client2 ~peer:node1 in
  let* () = Client.Admin.connect_address client1 ~peer:node2 in
  let* () =
    Sc_rollup_node.run sc_rollup_node ~event_level:`Debug sc_rollup []
  in
  (* We bake `sc_rollup_commitment_period_in_blocks - 1` levels, which
     should cause both nodes to observe level
     `sc_rollup_commitment_period_in_blocks + init_level - 1 . *)
  let* () = bake_levels (levels_to_commitment - 1) client1 in
  let* _ = Node.wait_for_level node2 (init_level + levels_to_commitment - 1) in
  let* _ = Sc_rollup_node.wait_sync ~timeout:3. sc_rollup_node in
  Log.info "Nodes are synchronized." ;
  Log.info "Forking." ;
  let* identity2 = Node.wait_for_identity node2 in
  let* () = Client.Admin.kick_peer client1 ~peer:identity2 in
  let* () = send_text_messages client1 ["message1"]
  and* () = send_text_messages client2 ["message2"] in
  let* header1 = Client.RPC.call client1 @@ RPC.get_chain_block_header ()
  and* header2 = Client.RPC.call client2 @@ RPC.get_chain_block_header () in
  let level1 = JSON.(header1 |-> "level" |> as_int) in
  let level2 = JSON.(header2 |-> "level" |> as_int) in
  let hash1 = JSON.(header1 |-> "hash" |> as_string) in
  let hash2 = JSON.(header2 |-> "hash" |> as_string) in
  Check.((level1 = level2) int)
    ~error_msg:"Heads levels should be identical but %L <> %R" ;
  Check.((JSON.encode header1 <> JSON.encode header2) string)
    ~error_msg:"Heads should be distinct: %L and %R" ;
  Log.info "Nodes are following distinct branches." ;
  let* _ = Sc_rollup_node.wait_sync ~timeout:10. sc_rollup_node in
  let check_sc_head hash =
    let* sc_head =
      Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
      @@ Sc_rollup_rpc.get_global_block_hash ()
    in
    let sc_head = JSON.as_string sc_head in
    Check.((sc_head = hash) string)
      ~error_msg:"Head of rollup node %L should be one of node %R" ;
    unit
  in
  let* () = check_sc_head hash1 in
  let* state_hash1 =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ~block:hash1 ()
  in
  Log.info "Changing L1 node for rollup node (1st reorg)" ;
  let* () =
    Sc_rollup_node.change_node_and_restart
      ~event_level:`Debug
      sc_rollup_node
      sc_rollup
      node2
  in
  let* _ = Sc_rollup_node.wait_sync ~timeout:10. sc_rollup_node in
  let* () = check_sc_head hash2 in
  let* state_hash2 =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ~block:hash2 ()
  in
  Log.info
    "Changing L1 node for rollup node (2nd reorg), back to first node to \
     simulate reproposal of round 0" ;
  let* () =
    Sc_rollup_node.change_node_and_restart
      ~event_level:`Debug
      sc_rollup_node
      sc_rollup
      node1
  in
  let* _ = Sc_rollup_node.wait_sync ~timeout:10. sc_rollup_node in
  let* () = check_sc_head hash1 in
  Check.((state_hash1 <> state_hash2) string)
    ~error_msg:"States should be distinct" ;
  let state_hash_to_commit = state_hash1 in
  (* exactly one level left to finalize the commitment in the node. *)
  let* () = bake_levels (block_finality_time + 2) client1 in
  let* commitment =
    Client.RPC.call client1
    @@ RPC
       .get_chain_block_context_smart_rollups_smart_rollup_staker_staked_on_commitment
         ~sc_rollup
         Constant.bootstrap1.public_key_hash
  in
  let commitment_state_hash =
    JSON.(commitment |-> "compressed_state" |> as_string)
  in
  Check.((commitment_state_hash = state_hash_to_commit) string)
    ~error_msg:"Safety error: committed state %L instead of state %R" ;
  unit

type balances = {liquid : int; frozen : int}

let contract_balances ~pkh client =
  let* liquid =
    Client.RPC.call client
    @@ RPC.get_chain_block_context_contract_balance ~id:pkh ()
  in
  let* frozen =
    Client.RPC.call client
    @@ RPC.get_chain_block_context_contract_frozen_bonds ~id:pkh ()
  in
  return {liquid = Tez.to_mutez liquid; frozen = Tez.to_mutez frozen}

(** This helper allow to attempt recovering bond for SCORU rollup operator.
    if [expect_failure] is set to some string then, we expect the command to fail
    with an error that contains that string. *)
let attempt_withdraw_stake =
  let check_eq_int a b =
    Check.((a = b) int ~error_msg:"expected value %L, got %R")
  in
  fun ?expect_failure
      ~sc_rollup
      ~sc_rollup_stake_amount
      ?(check_liquid_balance = true)
      ?(src = Constant.bootstrap1.public_key_hash)
      ?(staker = Constant.bootstrap1.public_key_hash)
      ?(keys = [Constant.bootstrap2.alias])
      client ->
    let recover_bond_fee = 1_000_000 in
    let inject_op () =
      Client.Sc_rollup.submit_recover_bond
        ~hooks
        ~rollup:sc_rollup
        ~src
        ~fee:(Tez.of_mutez_int recover_bond_fee)
        ~staker
        client
    in
    match expect_failure with
    | None ->
        let*! () = inject_op () in
        let* old_bal = contract_balances ~pkh:staker client in
        let* () = Client.bake_for_and_wait ~keys client in
        let* new_bal = contract_balances ~pkh:staker client in
        let expected_liq_new_bal =
          old_bal.liquid - recover_bond_fee + sc_rollup_stake_amount
        in
        if check_liquid_balance then
          check_eq_int new_bal.liquid expected_liq_new_bal ;
        check_eq_int new_bal.frozen (old_bal.frozen - sc_rollup_stake_amount) ;
        unit
    | Some failure_string ->
        let*? p = inject_op () in
        Process.check_error ~msg:(rex failure_string) p

(* Test that nodes do not publish commitments before the last cemented commitment. *)
let commitment_before_lcc_not_published protocol sc_rollup_node sc_rollup node
    client =
  let* constants = get_sc_rollup_constants client in
  let commitment_period = constants.commitment_period_in_blocks in
  let challenge_window = constants.challenge_window_in_blocks in
  (* Rollup node 1 processes messages, produces and publishes two commitments. *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in

  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* () = bake_levels commitment_period client in
  let* commitment_inbox_level =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + commitment_period)
  in
  let* _level = bake_until_lpc_updated client sc_rollup_node in
  let* {commitment = _; hash = rollup_node1_stored_hash} =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  let* rollup_node1_published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  let () =
    Check.(
      rollup_node1_published_commitment.commitment_and_hash.commitment
        .inbox_level = commitment_inbox_level)
      Check.int
      ~error_msg:
        "Commitment has been published at a level different than expected (%L \
         = %R)"
  in
  (* Cement commitment manually: the commitment can be cemented after
     `challenge_window_levels` have passed since the commitment was published
     (that is at level `commitment_finalized_level`). Note that at this point
     we are already at level `commitment_finalized_level`, hence cementation of
     the commitment can happen. *)
  let levels_to_cementation = challenge_window in
  let cemented_commitment_hash =
    rollup_node1_published_commitment.commitment_and_hash.hash
  in
  let* () = bake_levels levels_to_cementation client in
  let* _ =
    let* current_level = Node.get_level node in
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node current_level
  in

  (* Withdraw stake before cementing should fail *)
  let* () =
    attempt_withdraw_stake
      ~sc_rollup
      ~sc_rollup_stake_amount:(Tez.to_mutez constants.stake_amount)
      client
      ~keys:[]
      ~expect_failure:
        "Attempted to withdraw while not staked on the last cemented \
         commitment."
  in

  let* () =
    cement_commitment protocol client ~sc_rollup ~hash:cemented_commitment_hash
  in
  let* _ =
    let* current_level = Node.get_level node in
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node current_level
  in

  (* Withdraw stake after cementing should succeed *)
  let* () =
    attempt_withdraw_stake
      ~sc_rollup
      ~sc_rollup_stake_amount:(Tez.to_mutez constants.stake_amount)
      ~keys:[]
      ~check_liquid_balance:false
      client
  in

  let* () = Sc_rollup_node.terminate sc_rollup_node in
  (* Rollup node 2 starts and processes enough levels to publish a commitment.*)
  let bootstrap2_key = Constant.bootstrap2.public_key_hash in
  let* client' = Client.init ?endpoint:(Some (Node node)) () in
  let sc_rollup_node' =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client')
      ~default_operator:bootstrap2_key
  in
  let* () = Sc_rollup_node.run sc_rollup_node' sc_rollup [] in

  let* _ = wait_for_current_level node ~timeout:3. sc_rollup_node' in
  (* Check that no commitment was published. *)
  let* {body = rollup_node2_last_published_commitment; _} =
    Sc_rollup_node.RPC.call_json sc_rollup_node'
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  let () =
    Check.(JSON.is_null rollup_node2_last_published_commitment = true)
      Check.bool
      ~error_msg:"Commitment has been published by node 2 at %L but shouldn't"
  in
  (* Check that the commitment stored by the second rollup node
     is the same commmitment stored by the first rollup node. *)
  let* {commitment = _; hash = rollup_node2_stored_hash} =
    Sc_rollup_node.RPC.call sc_rollup_node'
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  let () =
    Check.(rollup_node1_stored_hash = rollup_node2_stored_hash)
      Check.string
      ~error_msg:
        "Commitments stored by first (%L) and second (%R) rollup nodes differ"
  in

  (* Bake other commitment_period levels and check that rollup_node2 is
     able to publish a commitment (bake one extra to see commitment in block). *)
  let* () = bake_levels (commitment_period + 1) client' in
  let commitment_inbox_level = commitment_inbox_level + commitment_period in
  let* _ = wait_for_current_level node ~timeout:3. sc_rollup_node' in
  let* rollup_node2_last_published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node'
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  let rollup_node2_last_published_commitment_inbox_level =
    rollup_node2_last_published_commitment.commitment_and_hash.commitment
      .inbox_level
  in
  let () =
    Check.(
      rollup_node2_last_published_commitment_inbox_level
      = commitment_inbox_level)
      Check.int
      ~error_msg:
        "Commitment has been published at a level different than expected (%L \
         = %R)"
  in
  let () =
    Check.(
      rollup_node2_last_published_commitment.commitment_and_hash.commitment
        .predecessor = cemented_commitment_hash)
      Check.string
      ~error_msg:
        "Predecessor fo commitment published by rollup_node2 should be the \
         cemented commitment (%L = %R)"
  in
  unit

(* Test that the level when a commitment was first published is fetched correctly
   by rollup nodes. *)
let first_published_level_is_global _protocol sc_rollup_node sc_rollup node
    client =
  (* Rollup node 1 processes messages, produces and publishes two commitments. *)
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let* commitment_period = get_sc_rollup_commitment_period_in_blocks client in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* level =
    Sc_rollup_node.wait_for_level ~timeout:3. sc_rollup_node init_level
  in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* () = bake_levels commitment_period client in
  let* commitment_inbox_level =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      (init_level + commitment_period)
  in
  let* commitment_publish_level =
    bake_until_lpc_updated client sc_rollup_node
  in
  let* rollup_node1_published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  Check.(
    rollup_node1_published_commitment.commitment_and_hash.commitment.inbox_level
    = commitment_inbox_level)
    Check.int
    ~error_msg:
      "Commitment has been published for a level %L different than expected %R" ;
  Check.(
    rollup_node1_published_commitment.first_published_at_level
    = Some commitment_publish_level)
    (Check.option Check.int)
    ~error_msg:
      "Level at which commitment has first been published (%L) is wrong. \
       Expected %R." ;
  let* () = Sc_rollup_node.terminate sc_rollup_node in
  (* Rollup node 2 starts and processes enough levels to publish a commitment.*)
  let bootstrap2_key = Constant.bootstrap2.public_key_hash in
  let* client' = Client.init ?endpoint:(Some (Node node)) () in
  let sc_rollup_node' =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client')
      ~default_operator:bootstrap2_key
  in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node' sc_rollup []
  in

  let* _ =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node'
      commitment_publish_level
  in
  let* {body = rollup_node2_published_commitment; _} =
    Sc_rollup_node.RPC.call_json sc_rollup_node'
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  Check.(JSON.is_null rollup_node2_published_commitment = true)
    Check.bool
    ~error_msg:"Rollup node 2 cannot publish commitment without any new block." ;
  let* _level = bake_until_lpc_updated client sc_rollup_node' in
  let* rollup_node2_published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node'
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  check_commitment_eq
    ( rollup_node1_published_commitment.commitment_and_hash.commitment,
      "published by rollup node 1" )
    ( rollup_node2_published_commitment.commitment_and_hash.commitment,
      "published by rollup node 2" ) ;
  let () =
    Check.(
      rollup_node1_published_commitment.first_published_at_level
      = rollup_node2_published_commitment.first_published_at_level)
      (Check.option Check.int)
      ~error_msg:
        "Rollup nodes do not agree on level when commitment was first \
         published (%L = %R)"
  in
  unit

(* Check that the SC rollup is correctly originated with a boot sector.
   -------------------------------------------------------

   Originate a rollup with a custom boot sector and check if the rollup's
   genesis state hash is correct.
*)
let test_rollup_origination_boot_sector ~boot_sector ~kind =
  test_full_scenario
    ~boot_sector
    ~kind
    {
      variant = None;
      tags = ["boot_sector"];
      description = "boot_sector is correctly set";
    }
  @@ fun _protocol rollup_node sc_rollup _tezos_node tezos_client ->
  let* genesis_info =
    Client.RPC.call ~hooks tezos_client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let genesis_commitment_hash =
    JSON.(genesis_info |-> "commitment_hash" |> as_string)
  in
  let* init_commitment =
    Client.RPC.call ~hooks tezos_client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_commitment
         ~sc_rollup
         ~hash:genesis_commitment_hash
         ()
  in
  let init_hash = init_commitment.compressed_state in
  let* () = Sc_rollup_node.run rollup_node sc_rollup [] in
  let* _ = Sc_rollup_node.wait_for_level ~timeout:3. rollup_node init_level in
  let* node_state_hash =
    Sc_rollup_node.RPC.call ~rpc_hooks rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ()
  in
  Check.(
    (init_hash = node_state_hash)
      string
      ~error_msg:"State hashes should be equal! (%L, %R)") ;
  unit

(** Check that a node makes use of the boot sector.
    -------------------------------------------------------

    Originate 2 rollups with different boot sectors to check if they have
    different hash.
*)
let test_boot_sector_is_evaluated ~boot_sector1 ~boot_sector2 ~kind =
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/4161

     The hash is calculated by the client and given as a proof to the L1. This test
     should be rewritten in a unit test maybe ?
  *)
  test_l1_scenario
    ~regression:true
    ~hooks
    ~boot_sector:boot_sector1
    ~kind
    {
      variant = None;
      tags = ["boot_sector"];
      description = "boot sector is evaluated";
    }
  @@ fun _protocol sc_rollup1 _tezos_node tezos_client ->
  let* sc_rollup2 =
    originate_sc_rollup
      ~alias:"rollup2"
      ~hooks
      ~kind
      ~boot_sector:boot_sector2
      ~src:Constant.bootstrap2.alias
      tezos_client
  in
  let genesis_state_hash ~sc_rollup tezos_client =
    let* genesis_info =
      Client.RPC.call ~hooks tezos_client
      @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
           sc_rollup
    in
    let commitment_hash =
      JSON.(genesis_info |-> "commitment_hash" |> as_string)
    in
    let* commitment =
      Client.RPC.call ~hooks tezos_client
      @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_commitment
           ~sc_rollup
           ~hash:commitment_hash
           ()
    in
    let state_hash = commitment.compressed_state in
    return state_hash
  in

  let* state_hash_1 = genesis_state_hash ~sc_rollup:sc_rollup1 tezos_client in
  let* state_hash_2 = genesis_state_hash ~sc_rollup:sc_rollup2 tezos_client in
  Check.(
    (state_hash_1 <> state_hash_2)
      string
      ~error_msg:"State hashes should be different! (%L, %R)") ;
  unit

let test_reveals_fails_on_wrong_hash =
  let kind = "arith" in
  test_full_scenario
    ~timeout:120
    ~kind
    {
      tags = ["reveals"; "wrong"];
      variant = None;
      description = "reveal data fails with wrong hash";
    }
  @@ fun protocol sc_rollup_node sc_rollup node client ->
  let hash = reveal_hash ~protocol ~kind "Some data" in
  let pvm_dir = Filename.concat (Sc_rollup_node.data_dir sc_rollup_node) kind in
  let filename = Filename.concat pvm_dir hash.filename in
  let () = Sys.mkdir pvm_dir 0o700 in
  let cout = open_out filename in
  let () = output_string cout "Some data that is not related to the hash" in
  let () = close_out cout in

  let error_promise =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "smart_rollup_node_daemon_error.v0"
      (fun e ->
        let id = JSON.(e |=> 0 |-> "id" |> as_string) in
        if id =~ rex "wrong_hash_of_reveal_preimage" then Some () else None)
  in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* () = send_text_messages client [hash.message] in
  let should_not_sync =
    let* _level = wait_for_current_level node ~timeout:10. sc_rollup_node in
    Test.fail "The rollup node processed the incorrect reveal without failing"
  in
  Lwt.choose [error_promise; should_not_sync]

let test_reveals_fails_on_unknown_hash =
  let kind = "arith" in
  test_full_scenario
    ~supports:(Protocol.From_protocol 17)
    ~timeout:120
    ~kind
    ~allow_degraded:true
    {
      tags = ["reveals"; "unknown"];
      variant = None;
      description = "reveal data fails with unknown hash";
    }
  @@ fun _protocol sc_rollup_node sc_rollup node client ->
  let unknown_hash =
    "0027782d2a7020be332cc42c4e66592ec50305f559a4011981f1d5af81428ecafe"
  in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let error_promise =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "smart_rollup_node_daemon_error.v0"
      (fun e ->
        let id = JSON.(e |=> 0 |-> "id" |> as_string) in
        if id =~ rex "could_not_open_reveal_preimage_file" then Some ()
        else None)
  in
  (* We need to check that the rollup has entered the degraded mode,
      so we wait for 60 blocks (commitment period) + 2. *)
  let* {commitment_period_in_blocks; _} = get_sc_rollup_constants client in
  let* () =
    repeat (commitment_period_in_blocks + 2) (fun () ->
        Client.bake_for_and_wait client)
  in
  (* Then, we finally send the message with the unknown hash. *)
  let* () = send_text_messages client ["hash:" ^ unknown_hash] in
  let should_not_sync =
    let* _level = wait_for_current_level node ~timeout:10. sc_rollup_node in
    Test.fail "The rollup node processed the unknown reveal without failing"
  in
  Lwt.choose [error_promise; should_not_sync]

let test_reveals_4k =
  let kind = "arith" in
  test_full_scenario
    ~timeout:120
    ~kind
    {
      tags = ["reveals"; "4k"];
      variant = None;
      description = "reveal 4kB of data";
    }
  @@ fun protocol sc_rollup_node sc_rollup node client ->
  let data = String.make 4096 'z' in
  let hash = reveal_hash ~protocol ~kind data in
  let pvm_dir = Filename.concat (Sc_rollup_node.data_dir sc_rollup_node) kind in
  let filename = Filename.concat pvm_dir hash.filename in
  let () = Sys.mkdir pvm_dir 0o700 in
  let () = with_open_out filename @@ fun cout -> output_string cout data in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let failure =
    let* () =
      Sc_rollup_node.process sc_rollup_node |> Option.get |> Process.check
    in
    Test.fail "Node terminated before reveal"
  in
  let* () = send_text_messages client [hash.message] in
  let sync =
    let* _level = wait_for_current_level node ~timeout:10. sc_rollup_node in
    unit
  in
  Lwt.choose [sync; failure]

(** Run simple http server on [port] that servers static files in the [root] directory. *)
let serve_files ?(on_request = fun _ -> ()) ~name ~port ~root f =
  let server =
    Cohttp_lwt_unix.Server.make () ~callback:(fun _conn request _body ->
        match request.meth with
        | `GET ->
            let fname =
              Cohttp.Path.resolve_local_file
                ~docroot:root
                ~uri:(Cohttp.Request.uri request)
            in
            Log.debug ~prefix:name "Request file %s@." fname ;
            on_request fname ;
            Cohttp_lwt_unix.Server.respond_file ~fname ()
        | _ ->
            Cohttp_lwt_unix.Server.respond_error
              ~status:`Method_not_allowed
              ~body:"Static file server only answers GET"
              ())
  in
  let stop, stopper = Lwt.task () in
  let serve =
    Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Port port)) server
  in
  let stopper () =
    Log.debug ~prefix:name "Stopping" ;
    Lwt.wakeup_later stopper () ;
    serve
  in
  Lwt.finalize f stopper

let test_reveals_fetch_remote =
  let kind = "arith" in
  test_full_scenario
    ~timeout:120
    ~kind
    {
      tags = ["reveals"; "fetch"];
      variant = None;
      description = "reveal from remote service";
    }
  @@ fun protocol sc_rollup_node sc_rollup node client ->
  let data = String.make 1024 '\202' in
  let hash = reveal_hash ~protocol ~kind data in
  let pre_images_dir = Temp.dir "preimages_remote_dir" in
  let filename = Filename.concat pre_images_dir hash.filename in
  let () = with_open_out filename @@ fun cout -> output_string cout data in
  let provider_port = Port.fresh () in
  Log.info "Starting webserver for static pre-images content." ;
  let fetched = ref false in
  serve_files
    ~name:"pre_image_provider"
    ~port:provider_port
    ~root:pre_images_dir
    ~on_request:(fun _ -> fetched := true)
  @@ fun () ->
  let pre_images_endpoint =
    sf "http://%s:%d" Constant.default_host provider_port
  in
  Log.info "Run rollup node." ;
  let* () =
    Sc_rollup_node.run
      sc_rollup_node
      sc_rollup
      [Pre_images_endpoint pre_images_endpoint]
  in
  let failure =
    let* () =
      Sc_rollup_node.process sc_rollup_node |> Option.get |> Process.check
    in
    Test.fail "Node terminated before reveal"
  in
  Log.info "Send reveal message %s." hash.message ;
  let* () = send_text_messages client [hash.message] in
  let sync =
    let* _level = wait_for_current_level node ~timeout:10. sc_rollup_node in
    if not !fetched then
      Test.fail ~__LOC__ "Pre-image was not fetched from remote server" ;
    unit
  in
  Lwt.choose [sync; failure]

let test_reveals_above_4k =
  let kind = "arith" in
  test_full_scenario
    ~timeout:120
    ~kind
    {
      tags = ["reveals"; "4k"];
      variant = None;
      description = "reveal more than 4kB of data";
    }
  @@ fun protocol sc_rollup_node sc_rollup node client ->
  let data = String.make 4097 'z' in
  let hash = reveal_hash ~protocol ~kind data in
  let pvm_dir = Filename.concat (Sc_rollup_node.data_dir sc_rollup_node) kind in
  let filename = Filename.concat pvm_dir hash.filename in
  let () = Sys.mkdir pvm_dir 0o700 in
  let cout = open_out filename in
  let () = output_string cout data in
  let () = close_out cout in
  let error_promise =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "smart_rollup_node_daemon_error.v0"
      (fun e ->
        let id = JSON.(e |=> 0 |-> "id" |> as_string) in
        if id =~ rex "could_not_encode_raw_data" then Some () else None)
  in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* () = send_text_messages client [hash.message] in
  let should_not_sync =
    let* _level = wait_for_current_level node ~timeout:10. sc_rollup_node in
    Test.fail "The rollup node processed the incorrect reveal without failing"
  in
  Lwt.choose [error_promise; should_not_sync]

let test_consecutive_commitments _protocol _rollup_node sc_rollup _tezos_node
    tezos_client =
  let* inbox_level = Client.level tezos_client in
  let operator = Constant.bootstrap1.public_key_hash in
  let* {commitment_period_in_blocks; _} =
    get_sc_rollup_constants tezos_client
  in
  (* As we did no publish any commitment yet, this is supposed to fail. *)
  let*? process =
    Client.RPC.spawn tezos_client
    @@ RPC
       .get_chain_block_context_smart_rollups_smart_rollup_staker_staked_on_commitment
         ~sc_rollup
         operator
  in
  let* () =
    Process.check_error
      ~msg:(rex "This implicit account is not a staker of this smart rollup")
      process
  in
  let* _commit, commit_hash =
    bake_period_then_publish_commitment ~sc_rollup ~src:operator tezos_client
  in
  let* () =
    repeat (commitment_period_in_blocks + 2) (fun () ->
        Client.bake_for_and_wait tezos_client)
  in
  let* _commit, _commit_hash =
    forge_and_publish_commitment
      ~inbox_level:(inbox_level + (2 * commitment_period_in_blocks))
      ~predecessor:commit_hash
      ~sc_rollup
      ~src:operator
      tezos_client
  in
  unit

let test_cement_ignore_commitment ~kind =
  let commitment_period = 3 in
  let challenge_window = 3 in
  test_commitment_scenario
  (* this test can be removed when oxford is activated because the
     commitment in the cement operation have been removed. *)
    ~supports:Protocol.(Until_protocol 17)
    ~commitment_period
    ~challenge_window
    ~kind
    ~variant:"cement_ignore_commitment"
  @@ fun protocol _sc_rollup_node sc_rollup node client ->
  let sc_rollup_node =
    Sc_rollup_node.create
      (Custom [Sc_rollup_node.Publish])
      node
      ~base_dir:(Client.base_dir client)
      ~operators:[(Sc_rollup_node.Operating, Constant.bootstrap1.alias)]
    (* Don't cement commitments *)
  in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* _level = Sc_rollup_node.wait_sync ~timeout:3. sc_rollup_node in
  let* _level = bake_until_lpc_updated client sc_rollup_node in
  let* _level = Sc_rollup_node.wait_sync ~timeout:10. sc_rollup_node in
  let* () = bake_levels challenge_window client in
  let* _level = Sc_rollup_node.wait_sync ~timeout:10. sc_rollup_node in
  let* () =
    let hash =
      (* zero commitment hash *)
      "src12UJzB8mg7yU6nWPzicH7ofJbFjyJEbHvwtZdfRXi8DQHNp1LY8"
    in
    cement_commitment protocol client ~sc_rollup ~hash
  in
  let* _level = Sc_rollup_node.wait_sync ~timeout:10. sc_rollup_node in
  unit

let test_refutation_scenario ?commitment_period ?challenge_window ~variant ~mode
    ~kind ({allow_degraded; _} as scenario) =
  let regression =
    (* TODO: https://gitlab.com/tezos/tezos/-/issues/5313
       Disabled dissection regressions for parallel games, as it introduces
       flakyness. *)
    List.compare_length_with scenario.loser_modes 1 <= 0
  in
  let tags =
    ["refutation"] @ if mode = Sc_rollup_node.Accuser then ["accuser"] else []
  in
  let variant = variant ^ if mode = Accuser then "+accuser" else "" in
  test_full_scenario
    ~regression
    ?hooks:None (* We only want to capture dissections manually *)
    ?commitment_period
    ~kind
    ~mode
    ~timeout:60
    ?challenge_window
    ~rollup_node_name:"honest"
    ~allow_degraded
    {
      tags;
      variant = Some variant;
      description = "refutation games winning strategies";
    }
    (test_refutation_scenario_aux ~mode ~kind scenario)

let test_refutation protocols ~kind =
  let challenge_window = 10 in
  let commitment_period = 10 in
  let tests =
    match kind with
    | "arith" ->
        [
          (* As a reminder, the format of loser modes is a space-separated
             list of space-separated triples of integers. The first integer
             is the inbox level of the failure, the second integer is the
             message index of the failure, and the third integer is the
             index of the failing tick during the processing of this
             message. *)
          ( "inbox_proof_at_genesis",
            refutation_scenario_parameters
              ~loser_modes:["3 0 0"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "pvm_proof_at_genesis",
            refutation_scenario_parameters
              ~loser_modes:["3 0 1"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "inbox_proof",
            refutation_scenario_parameters
              ~loser_modes:["5 0 0"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "inbox_proof_with_new_content",
            refutation_scenario_parameters
              ~loser_modes:["5 0 0"]
              (inputs_for 30)
              ~final_level:80
              ~priority:`Priority_honest );
          (* In "inbox_proof_with_new_content" we add messages after the commitment
             period so the current inbox is not equal to the inbox snapshot-ted at the
             game creation. *)
          ( "inbox_proof_one_empty_level",
            refutation_scenario_parameters
              ~loser_modes:["6 0 0"]
              (inputs_for 10)
              ~final_level:80
              ~empty_levels:[2]
              ~priority:`Priority_honest );
          ( "inbox_proof_many_empty_levels",
            refutation_scenario_parameters
              ~loser_modes:["9 0 0"]
              (inputs_for 10)
              ~final_level:80
              ~empty_levels:[2; 3; 4]
              ~priority:`Priority_honest );
          ( "pvm_proof_0",
            refutation_scenario_parameters
              ~loser_modes:["5 2 1"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "pvm_proof_1",
            refutation_scenario_parameters
              ~loser_modes:["7 2 0"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "pvm_proof_2",
            refutation_scenario_parameters
              ~loser_modes:["7 2 5"]
              (inputs_for 7)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "pvm_proof_3",
            refutation_scenario_parameters
              ~loser_modes:["9 2 5"]
              (inputs_for 7)
              ~final_level:80
              ~empty_levels:[4; 5]
              ~priority:`Priority_honest );
          ( "timeout",
            refutation_scenario_parameters
              ~loser_modes:["5 2 1"]
              (inputs_for 10)
              ~final_level:80
              ~stop_loser_at:[35]
              ~priority:`Priority_honest );
          ( "reset_honest_during_game",
            refutation_scenario_parameters
              ~loser_modes:["5 2 1"]
              (inputs_for 10)
              ~final_level:80
              ~reset_honest_on:
                [("smart_rollup_node_conflict_detected.v0", 2, None)]
              ~priority:`Priority_honest );
          ( "degraded_new",
            refutation_scenario_parameters
              ~loser_modes:["7 2 5"]
              (inputs_for 7)
              ~final_level:80
              ~bad_reveal_at:
                [
                  14
                  (* Commitment for inbox 7 will be made at level 12 and published
                     at level 14 *);
                ]
              ~allow_degraded:true
              ~priority:`Priority_honest );
          ( "degraded_ongoing",
            refutation_scenario_parameters
              ~loser_modes:["7 2 5"]
              (inputs_for 7)
              ~final_level:80
              ~bad_reveal_at:[21]
              ~allow_degraded:true
              ~priority:`Priority_honest );
          ( "parallel_games_0",
            refutation_scenario_parameters
              ~loser_modes:["3 0 0"; "3 0 1"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_honest );
          ( "parallel_games_1",
            refutation_scenario_parameters
              ~loser_modes:["3 0 0"; "3 0 1"; "3 0 0"]
              (inputs_for 10)
              ~final_level:200
              ~priority:`Priority_honest );
        ]
    | "wasm_2_0_0" ->
        [
          (* First message of an inbox (level 3) *)
          ( "inbox_proof_0",
            refutation_scenario_parameters
              ~loser_modes:["3 0 0"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          (* Fourth message of an inbox (level 3) *)
          ( "inbox_proof_1",
            refutation_scenario_parameters
              ~loser_modes:["3 4 0"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          (* Echo kernel takes around 2,100 ticks to execute *)
          (* Second tick of decoding *)
          ( "pvm_proof_0",
            refutation_scenario_parameters
              ~loser_modes:["5 7 11_000_000_001"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          ( "pvm_proof_1",
            refutation_scenario_parameters
              ~loser_modes:["7 7 11_000_001_000"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          (* End of evaluation *)
          ( "pvm_proof_2",
            refutation_scenario_parameters
              ~loser_modes:["7 7 22_000_002_000"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          (* During padding *)
          ( "pvm_proof_3",
            refutation_scenario_parameters
              ~loser_modes:["7 7 22_010_000_000"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          ( "parallel_games_0",
            refutation_scenario_parameters
              ~loser_modes:["4 0 0"; "5 7 11_000_000_001"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
          ( "parallel_games_1",
            refutation_scenario_parameters
              ~loser_modes:["4 0 0"; "7 7 22_000_002_000"; "7 7 22_000_002_000"]
              (inputs_for 10)
              ~final_level:80
              ~priority:`Priority_loser );
        ]
    | _ -> assert false
  in
  List.iter
    (fun (variant, inputs) ->
      test_refutation_scenario
        ~kind
        ~mode:Operator
        ~challenge_window
        ~commitment_period
        ~variant
        inputs
        protocols)
    tests

(** Run one of the refutation tests with an accuser instead of a full operator. *)
let test_accuser protocols =
  test_refutation_scenario
    ~kind:"wasm_2_0_0"
    ~mode:Accuser
    ~challenge_window:10
    ~commitment_period:10
    ~variant:"pvm_proof_2"
    (refutation_scenario_parameters
       ~loser_modes:["7 7 22_000_002_000"]
       (inputs_for 10)
       ~final_level:80
       ~priority:`Priority_honest)
    protocols

(** Run one of the refutation tests in bailout mode instead of using a
    full operator. *)
let test_bailout_refutation protocols =
  test_refutation_scenario
    ~kind:"arith"
    ~mode:Operator
    ~challenge_window:10
    ~commitment_period:10
    ~variant:"bailout_mode_defends_its_commitment"
    (refutation_scenario_parameters
       ~loser_modes:["5 2 1"]
       (inputs_for 10)
       ~final_level:80
       ~reset_honest_on:
         [("smart_rollup_node_conflict_detected.v0", 2, Some Bailout)]
       ~priority:`Priority_honest)
    protocols

(** Run the node in bailout mode, the node will exit with an error,
    when it's run without an operator key *)
let bailout_mode_fail_to_start_without_operator ~kind =
  test_l1_scenario
    ~kind
    {
      variant = None;
      tags = ["rollup_node"; "mode"; "bailout"];
      description = "rollup node in bailout fails without operator";
    }
    ~uses:(fun _protocol -> [Constant.octez_smart_rollup_node])
  @@ fun _protocol sc_rollup tezos_node tezos_client ->
  let sc_rollup_node =
    Sc_rollup_node.create
      Bailout
      tezos_node
      ~base_dir:(Client.base_dir tezos_client)
      ~operators:
        [
          (Sc_rollup_node.Cementing, Constant.bootstrap1.alias);
          (Sc_rollup_node.Recovering, Constant.bootstrap1.alias);
        ]
  in
  let* () = Sc_rollup_node.run ~wait_ready:false sc_rollup_node sc_rollup []
  and* () =
    Sc_rollup_node.check_error
      ~exit_code:1
      ~msg:(rex "Missing operator for the purpose of operating.")
      sc_rollup_node
  in
  unit

(** Start a bailout rollup node, fails directly as the operator has not stake. *)
let bailout_mode_fail_operator_no_stake ~kind =
  let _operator = Constant.bootstrap1.public_key_hash in
  test_full_scenario
    ~kind
    ~mode:Bailout
    {
      variant = None;
      tags = ["mode"; "bailout"];
      description = "rollup node in bailout fails operator has no stake";
    }
  @@ fun _protocol sc_rollup_node sc_rollup _tezos_node _tezos_client ->
  let* () = Sc_rollup_node.run ~wait_ready:false sc_rollup_node sc_rollup []
  and* () =
    Sc_rollup_node.check_error
      sc_rollup_node
      ~exit_code:1
      ~msg:(rex "This implicit account is not a staker of this smart rollup.")
  in
  unit

(** Bailout mode operator has no stake, scenario:
    - start an operator rollup and wait until it publish a commitment
    - stop the rollup node
    - bakes until refutation period is over
    - using octez client cement the commitment
    - restart the rollup node in bailout mode
  check that it fails directly when the operator has no stake.
    *)
let bailout_mode_recover_bond_starting_no_commitment_staked ~kind =
  let operator = Constant.bootstrap1.public_key_hash in
  let commitment_period = 5 in
  let challenge_window = 5 in
  test_full_scenario
    ~kind
    {
      variant = None;
      tags = ["mode"; "bailout"];
      description =
        "rollup node in bailout recovers bond when starting if no commitment \
         staked";
    }
    ~commitment_period
    ~challenge_window
  @@ fun protocol sc_rollup_node sc_rollup tezos_node tezos_client ->
  let () = Log.info "Start the rollup in Operator mode" in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  (* bake until the first commitment is published *)
  let* _level =
    bake_until_lpc_updated
      ~at_least:commitment_period
      tezos_client
      sc_rollup_node
  in
  let* published_commitment =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  Log.info "Terminate the node" ;
  let* () = Sc_rollup_node.kill sc_rollup_node in
  Log.info "Bake until refutation period is over" ;
  let* () = bake_levels challenge_window tezos_client in
  (* manually cement the commitment *)
  let to_cement_commitment_hash =
    published_commitment.commitment_and_hash.hash
  in
  let* () =
    cement_commitment
      protocol
      tezos_client
      ~sc_rollup
      ~hash:to_cement_commitment_hash
  in
  let* () = Client.bake_for_and_wait tezos_client in
  Log.info "Check that there is still tezt in frozen balance" ;
  let* frozen_balance =
    Client.RPC.call tezos_client
    @@ RPC.get_chain_block_context_contract_frozen_bonds ~id:operator ()
  in
  let () =
    Check.(
      (Tez.to_mutez frozen_balance <> 0)
        int
        ~error_msg:
          "The operator should have a stake nor holds a frozen balance.")
  in
  let* staked_on =
    Client.RPC.call tezos_client
    @@ RPC
       .get_chain_block_context_smart_rollups_smart_rollup_staker_staked_on_commitment
         ~sc_rollup
         operator
  in
  let staked_on =
    (* We do not really care about the value *)
    Option.map (Fun.const ()) (JSON.as_opt staked_on)
  in
  let () =
    Check.(
      (staked_on = None)
        (option unit)
        ~error_msg:
          "The operator should have a stake but no commitment attached to it.")
  in
  Log.info
    "Start a rollup node in bailout mode, operator still has stake but no \
     attached commitment" ;
  let sc_rollup_node' =
    Sc_rollup_node.create
      Bailout
      tezos_node
      ~base_dir:(Client.base_dir tezos_client)
      ~default_operator:operator
  in
  let* () = Sc_rollup_node.run sc_rollup_node' sc_rollup []
  and* () =
    let event_name = "smart_rollup_node_daemon_exit_bailout_mode.v0" in
    bake_until_event tezos_client ~event_name
    @@ Sc_rollup_node.wait_for sc_rollup_node' event_name (Fun.const (Some ()))
  in
  Log.info "Check that the bond have been recovered by the rollup node" ;
  let* frozen_balance =
    Client.RPC.call tezos_client
    @@ RPC.get_chain_block_context_contract_frozen_bonds ~id:operator ()
  in
  let () =
    Check.(
      (Tez.to_mutez frozen_balance = 0)
        int
        ~error_msg:"The operator should have recovered its stake.")
  in
  unit

(** This helper function constructs the following commitment tree by baking and
    publishing commitments (but without cementing them):
    ---- c1 ---- c2 ---- c31 ---- c311
                  \
                   \---- c32 ---- c321

   Commits c1, c2, c31 and c311 are published by [operator1]. The forking
   branch c32 -- c321 is published by [operator2].
*)
let mk_forking_commitments node client ~sc_rollup ~operator1 ~operator2 =
  let* {commitment_period_in_blocks; _} = get_sc_rollup_constants client in
  (* This is the starting level on top of wich we'll construct the tree. *)
  let* starting_level = Node.get_level node in
  let mk_commit ~src ~ticks ~depth ~pred =
    (* Compute the inbox level for which we'd like to commit *)
    let inbox_level = starting_level + (commitment_period_in_blocks * depth) in
    (* d is the delta between the target inbox level and the current level *)
    let* current_level = Node.get_level node in
    let d = inbox_level - current_level + 1 in
    (* Bake sufficiently many blocks to be able to commit for the desired inbox
       level. We may actually bake no blocks if d <= 0 *)
    let* () = repeat d (fun () -> Client.bake_for_and_wait client) in
    let* _, commitment_hash =
      forge_and_publish_commitment
        ~inbox_level
        ~predecessor:pred
        ~sc_rollup
        ~number_of_ticks:ticks
        ~src
        client
    in
    return commitment_hash
  in
  (* Retrieve the latest commitment *)
  let* c0, _ = last_cemented_commitment_hash_with_level ~sc_rollup client in
  (* Construct the tree of commitments. Fork c32 and c321 is published by
     operator2. We vary ticks to have different hashes when commiting on top of
     the same predecessor. *)
  let* c1 = mk_commit ~ticks:1 ~depth:1 ~pred:c0 ~src:operator1 in
  let* c2 = mk_commit ~ticks:2 ~depth:2 ~pred:c1 ~src:operator1 in
  let* c31 = mk_commit ~ticks:31 ~depth:3 ~pred:c2 ~src:operator1 in
  let* c32 = mk_commit ~ticks:32 ~depth:3 ~pred:c2 ~src:operator2 in
  let* c311 = mk_commit ~ticks:311 ~depth:4 ~pred:c31 ~src:operator1 in
  let* c321 = mk_commit ~ticks:321 ~depth:4 ~pred:c32 ~src:operator2 in
  return (c1, c2, c31, c32, c311, c321)

(** This helper initializes a rollup and builds a commitment tree of the form:
    ---- c1 ---- c2 ---- c31 ---- c311
                  \
                   \---- c32 ---- c321
    Then, it calls the given scenario on it.
*)
let test_forking_scenario ~kind ~variant scenario =
  let commitment_period = 3 in
  let challenge_window = commitment_period * 7 in
  let timeout = 10 in
  test_l1_scenario
    ~challenge_window
    ~commitment_period
    ~timeout
    ~kind
    {
      tags = ["refutation"; "game"; "commitment"];
      variant = Some variant;
      description = "rollup with a commitment dispute";
    }
  @@ fun protocol sc_rollup tezos_node tezos_client ->
  (* Choosing challenge_windows to be quite longer than commitment_period
     to avoid being in a situation where the first commitment in the result
     of [mk_forking_commitments] is cementable without further bakes. *)

  (* Completely arbitrary as we decide when to trigger timeouts in tests.
     Making it a lot smaller than the default value to speed up tests. *)
  (* Building a forking commitments tree. *)
  let operator1 = Constant.bootstrap1 in
  let operator2 = Constant.bootstrap2 in
  let* level0 = Node.get_level tezos_node in
  let* commits =
    mk_forking_commitments
      tezos_node
      tezos_client
      ~sc_rollup
      ~operator1:operator1.public_key_hash
      ~operator2:operator2.public_key_hash
  in
  let* level1 = Node.get_level tezos_node in
  scenario
    tezos_client
    tezos_node
    protocol
    ~sc_rollup
    ~operator1
    ~operator2
    commits
    level0
    level1

(* A more convenient wrapper around [cement_commitment]. *)
let cement_commitments protocol client sc_rollup ?fail =
  Lwt_list.iter_s (fun hash ->
      cement_commitment protocol client ~sc_rollup ~hash ?fail)

(** Given a commitment tree constructed by {test_forking_scenario}, this function:
    - tests different (failing and non-failing) cementation of commitments
      and checks the returned error for each situation (in case of failure);
    - resolves the dispute on top of c2, and checks that the defeated branch
      is removed, while the alive one can be cemented.
*)
let test_no_cementation_if_parent_not_lcc_or_if_disputed_commit =
  test_forking_scenario ~variant:"publish, and cement on wrong commitment"
  @@ fun client
             _node
             protocol
             ~sc_rollup
             ~operator1
             ~operator2
             commits
             level0
             level1 ->
  let c1, c2, c31, c32, c311, _c321 = commits in
  let* constants = get_sc_rollup_constants client in
  let challenge_window = constants.challenge_window_in_blocks in
  let cement = cement_commitments protocol client sc_rollup in
  let missing_blocks_to_cement = level0 + challenge_window - level1 in
  let* () =
    if missing_blocks_to_cement <= 0 then unit (* We can already cement *)
    else
      let* () =
        repeat (missing_blocks_to_cement - 1) (fun () ->
            Client.bake_for_and_wait client)
      in
      (* We cannot cement yet! *)
      let* () = cement [c1] ~fail:commit_too_recent in
      (* After these blocks, we should be able to cement all commitments
         (modulo cementation ordering & disputes resolution) *)
      repeat challenge_window (fun () -> Client.bake_for_and_wait client)
  in
  (* c1 and c2 will be cemented. *)
  let* () = cement [c1; c2] in
  (* We cannot cement c31 or c32 on top of c2 because they are disputed *)
  let* () = cement [c31; c32] ~fail:disputed_commit in

  (* +++ dispute resolution +++
     Let's resolve the dispute between operator1 and operator2 on the fork
     c31 vs c32. [operator1] will make a bad initial dissection, so it
     loses the dispute, and the branch c32 --- c321 dies. *)

  (* [operator1] starts a dispute. *)
  let* () =
    start_refute
      client
      ~source:operator2
      ~opponent:operator1.public_key_hash
      ~sc_rollup
      ~player_commitment_hash:c32
      ~opponent_commitment_hash:c31
  in
  (* [operator1] will not play and will be timeout-ed. *)
  let timeout_period = constants.timeout_period_in_blocks in
  let* () =
    repeat (timeout_period + 1) (fun () -> Client.bake_for_and_wait client)
  in
  (* He even timeout himself, what a shame. *)
  let* () =
    timeout
      ~sc_rollup
      ~staker1:operator1.public_key_hash
      ~staker2:operator2.public_key_hash
      client
  in
  (* Now, we can cement c31 on top of c2 and c311 on top of c31. *)
  cement [c31; c311]

(** Given a commitment tree constructed by {test_forking_scenario}, this test
    starts a dispute and makes a first valid dissection move.
*)
let test_valid_dispute_dissection =
  test_forking_scenario ~variant:"valid dispute dissection"
  @@ fun client
             _node
             protocol
             ~sc_rollup
             ~operator1
             ~operator2
             commits
             _level0
             _level1 ->
  let c1, c2, c31, c32, _c311, _c321 = commits in
  let cement = cement_commitments protocol client sc_rollup in
  let* constants = get_sc_rollup_constants client in
  let challenge_window = constants.challenge_window_in_blocks in
  let commitment_period = constants.commitment_period_in_blocks in
  let* () =
    (* Be able to cement both c1 and c2 *)
    repeat (challenge_window + commitment_period) (fun () ->
        Client.bake_for_and_wait client)
  in
  let* () = cement [c1; c2] in
  let module M = Operation.Manager in
  (* The source initialises a dispute. *)
  let source = operator2 in
  let opponent = operator1.public_key_hash in
  let* () =
    start_refute
      client
      ~source
      ~opponent
      ~sc_rollup
      ~player_commitment_hash:c32
      ~opponent_commitment_hash:c31
  in
  (* If this hash needs to be recomputed, run this test with --verbose
     and grep for 'compressed_state' in the produced logs. *)
  let state_hash = "srs11Z9V76SGd97kGmDQXV8tEF67C48GMy77RuaHdF1kWLk6UTmMfj" in

  (* Inject a valid dissection move *)
  let* () =
    move_refute_with_unique_state_hash
      client
      ~source
      ~opponent
      ~sc_rollup
      ~state_hash
  in

  (* We cannot cement neither c31, nor c32 because refutation game hasn't
     ended. *)
  cement [c31; c32] ~fail:"Attempted to cement a disputed commitment"

(* Testing the timeout to record gas consumption in a regression trace and
   detect when the value changes.
   For functional tests on timing-out a dispute, see unit tests in
   [lib_protocol].

   For this test, we rely on [test_forking_scenario] to create a tree structure
   of commitments and we start a dispute.
   The first player is not even going to play, we'll simply bake enough blocks
   to get to the point where we can timeout. *)
let test_timeout =
  test_forking_scenario ~variant:"timeout"
  @@ fun client
             _node
             protocol
             ~sc_rollup
             ~operator1
             ~operator2
             commits
             level0
             level1 ->
  (* These are the commitments on the rollup. See [test_forking_scenario] to
       visualize the tree structure. *)
  let c1, c2, c31, c32, _c311, _c321 = commits in
  (* A helper function to cement a sequence of commitments. *)
  let cement = cement_commitments protocol client sc_rollup in
  let* constants = get_sc_rollup_constants client in
  let challenge_window = constants.challenge_window_in_blocks in
  let timeout_period = constants.timeout_period_in_blocks in

  (* Bake enough blocks to cement the commitments up to the divergence. *)
  let* () =
    repeat
      (* There are [level0 - level1 - 1] blocks between [level1] and
         [level0], plus the challenge window for [c1] and the one for [c2].
      *)
      (level0 - level1 - 1 + (2 * challenge_window))
      (fun () -> Client.bake_for_and_wait client)
  in
  let* () = cement [c1; c2] in

  let module M = Operation.Manager in
  (* [operator2] starts a dispute, but won't be playing then. *)
  let* () =
    start_refute
      client
      ~source:operator2
      ~opponent:operator1.public_key_hash
      ~sc_rollup
      ~player_commitment_hash:c32
      ~opponent_commitment_hash:c31
  in
  (* Get exactly to the block where we are able to timeout. *)
  let* () =
    repeat (timeout_period + 1) (fun () -> Client.bake_for_and_wait client)
  in
  timeout
    ~sc_rollup
    ~staker1:operator1.public_key_hash
    ~staker2:operator2.public_key_hash
    client

(* Testing rollup node catch up mechanism I
   --------------------------------------

   The rollup node must be able to catch up from the genesis
   of the rollup when paired with a node in archive mode.
*)
let test_late_rollup_node =
  test_full_scenario
    ~commitment_period:3
    {
      tags = ["late"];
      variant = None;
      description = "a late rollup should catch up";
    }
  @@ fun _protocol sc_rollup_node sc_rollup_address node client ->
  let* () = bake_levels 65 client in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup_address [] in
  let* () = bake_levels 30 client in
  let* _status = Sc_rollup_node.wait_for_level ~timeout:2. sc_rollup_node 95 in
  Log.info "First rollup node synchronized." ;
  let sc_rollup_node2 =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client)
      ~default_operator:
        Constant.bootstrap1.alias (* Same as other rollup_node *)
  in
  Log.info "Start rollup node from scratch with same operator" ;
  let* () = Sc_rollup_node.run sc_rollup_node2 sc_rollup_address [] in
  let* _level = wait_for_current_level node ~timeout:2. sc_rollup_node2 in
  Log.info "Other rollup node synchronized." ;
  let* () = Client.bake_for_and_wait client in
  let* _level = wait_for_current_level node ~timeout:2. sc_rollup_node2 in
  Log.info "Other rollup node progresses." ;
  unit

(* Testing rollup node catch up mechanism II
   --------------------------------------

   An alternative rollup node must be able to catch up from the genesis
   of the rollup when paired with a node in archive mode when there is
   already an other rollup node with a different operator already operating
   on the given rollup. This same alternative rollup node must be able to
   catch up a second time when it is stopped midway.
*)
let test_late_rollup_node_2 =
  test_full_scenario
    ~commitment_period:3
    ~challenge_window:10
    {
      tags = ["late"; "gc"];
      variant = None;
      description = "a late alternative rollup should catch up";
    }
  @@ fun _protocol sc_rollup_node sc_rollup_address node client ->
  let* () = bake_levels 65 client in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup_address [] in
  let* () = bake_levels 30 client in
  let* _status = Sc_rollup_node.wait_for_level ~timeout:2. sc_rollup_node 95 in
  Log.info "First rollup node synchronized." ;
  let sc_rollup_node2 =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client)
      ~default_operator:Constant.bootstrap2.alias
  in
  Log.info
    "Starting alternative rollup node from scratch with a different operator." ;
  (* Do gc every block, to test we don't remove live data *)
  let* () = Sc_rollup_node.run sc_rollup_node2 sc_rollup_address [] in
  let* _level = wait_for_current_level node ~timeout:20. sc_rollup_node2 in
  Log.info "Alternative rollup node is synchronized." ;
  let* () = Client.bake_for_and_wait client in
  let* _level = wait_for_current_level node ~timeout:2. sc_rollup_node2 in
  Log.info "Both rollup nodes are progressing and are synchronized." ;
  let* () = Sc_rollup_node.terminate sc_rollup_node2 in
  Log.info "Alternative rollup node terminated." ;
  let* () = bake_levels 30 client in
  let* () = Sc_rollup_node.run sc_rollup_node2 sc_rollup_address [] in
  Log.info "Alternative rollup node is re-running." ;
  let* () = bake_levels 30 client in
  let* _ = Sc_rollup_node.wait_for_level ~timeout:2. sc_rollup_node2 155 in
  Log.info
    "Alternative rollup node is synchronized once again after being terminated \
     once." ;
  unit

(* Test interruption of rollup node before the first inbox is processed. Upon
   restart the node should not complain that an inbox is missing. *)
let test_interrupt_rollup_node =
  test_full_scenario
    {
      tags = ["interrupt"];
      variant = None;
      description = "a rollup should recover on interruption before first inbox";
    }
  @@ fun _protocol sc_rollup_node sc_rollup _node client ->
  let processing_promise =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "smart_rollup_node_daemon_process_head.v0"
      (fun _ -> Some ())
  in
  let* () = bake_levels 15 client in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup []
  and* () = processing_promise in
  let* () = Sc_rollup_node.kill sc_rollup_node in
  let* () = bake_levels 1 client in
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* _ = Sc_rollup_node.wait_for_level ~timeout:20. sc_rollup_node 18 in
  unit

let test_refutation_reward_and_punishment ~kind =
  let timeout_period = 3 in
  let commitment_period = 2 in
  test_l1_scenario
    ~kind
    ~timeout:timeout_period
    ~commitment_period
    ~regression:true
    ~hooks
    {
      tags = ["refutation"; "reward"; "punishment"];
      variant = None;
      description = "participant of a refutation game are slashed/rewarded";
    }
  @@ fun _protocol sc_rollup node client ->
  (* Timeout is the easiest way to end a game, we set timeout period
         low to produce an outcome quickly. *)
  let* {commitment_period_in_blocks; stake_amount; _} =
    get_sc_rollup_constants client
  in
  let punishment = Tez.to_mutez stake_amount in
  let reward = punishment / 2 in

  (* Pick the two players and their initial balances. *)
  let operator1 = Constant.bootstrap2 in
  let operator2 = Constant.bootstrap3 in

  let* operator1_balances =
    contract_balances ~pkh:operator1.public_key_hash client
  in
  let* operator2_balances =
    contract_balances ~pkh:operator2.public_key_hash client
  in

  (* Retrieve the origination commitment *)
  let* c0, _ = last_cemented_commitment_hash_with_level ~sc_rollup client in

  (* Compute the inbox level for which we'd like to commit *)
  let* starting_level = Node.get_level node in
  let inbox_level = starting_level + commitment_period_in_blocks in
  (* d is the delta between the target inbox level and the current level *)
  let* current_level = Node.get_level node in
  let d = inbox_level - current_level + 1 in
  (* Bake sufficiently many blocks to be able to commit for the desired inbox
     level. We may actually bake no blocks if d <= 0 *)
  let* () = repeat d (fun () -> Client.bake_for_and_wait client) in

  (* [operator1] stakes on a commitment. *)
  let* _, operator1_commitment =
    forge_and_publish_commitment
      ~inbox_level
      ~predecessor:c0
      ~sc_rollup
      ~number_of_ticks:1
      ~src:operator1.public_key_hash
      client
  in
  let* new_operator1_balances =
    contract_balances ~pkh:operator1.public_key_hash client
  in

  Check.(
    (new_operator1_balances.frozen
    = operator1_balances.frozen + Tez.to_mutez stake_amount)
      int
      ~error_msg:"expecting frozen balance for operator1: %R, got %L") ;

  (* [operator2] stakes on a commitment. *)
  let* _, operator2_commitment =
    forge_and_publish_commitment
      ~inbox_level
      ~predecessor:c0
      ~sc_rollup
      ~number_of_ticks:2
      ~src:operator2.public_key_hash
      client
  in
  let* new_operator2_balances =
    contract_balances ~pkh:operator2.public_key_hash client
  in
  Check.(
    (new_operator2_balances.frozen
    = operator2_balances.frozen + Tez.to_mutez stake_amount)
      int
      ~error_msg:"expecting frozen balance for operator2: %R, got %L") ;

  let module M = Operation.Manager in
  (* [operator1] starts a dispute, but will never play. *)
  let* () =
    start_refute
      client
      ~source:operator1
      ~opponent:operator2.public_key_hash
      ~sc_rollup
      ~player_commitment_hash:operator1_commitment
      ~opponent_commitment_hash:operator2_commitment
  in
  (* Get exactly to the block where we are able to timeout. *)
  let* () =
    repeat (timeout_period + 1) (fun () -> Client.bake_for_and_wait client)
  in
  let* () =
    timeout
      ~sc_rollup
      ~staker1:operator2.public_key_hash
      ~staker2:operator1.public_key_hash
      ~src:Constant.bootstrap1.alias
      client
  in

  (* The game should have now ended. *)

  (* [operator2] wins half of the opponent's stake. *)
  let* final_operator2_balances =
    contract_balances ~pkh:operator2.public_key_hash client
  in
  Check.(
    (final_operator2_balances.frozen = new_operator2_balances.frozen)
      int
      ~error_msg:"operator2 should keep its frozen deposit: %R, got %L") ;
  Check.(
    (final_operator2_balances.liquid = new_operator2_balances.liquid + reward)
      int
      ~error_msg:"operator2 should win a reward: %R, got %L") ;

  (* [operator1] loses all its stake. *)
  let* final_operator1_balances =
    contract_balances ~pkh:operator1.public_key_hash client
  in
  Check.(
    (final_operator1_balances.frozen
    = new_operator1_balances.frozen - punishment)
      int
      ~error_msg:"operator1 should lose its frozen deposit: %R, got %L") ;

  unit

(* Testing the execution of outbox messages
   ----------------------------------------

   When the PVM interprets an input message that produces an output
   message, the outbox in the PVM state is populated with this output
   message. When the state is cemented (after the refutation period
   has passed without refutation), one can trigger the execution of
   the outbox message, that is a call to a given L1 contract.

   This test first populates an L1 contract that waits for an integer
   and stores this integer in its state. Then, the test executes a
   rollup operation that produces a call to this contract. Finally,
   the test triggers this call and we check that the L1 contract has
   been correctly executed by observing its local storage.

   The input depends on the PVM.
*)
let test_outbox_message_generic ?supports ?regression ?expected_error
    ?expected_l1_error ~earliness ?entrypoint ~init_storage ~storage_ty
    ?outbox_parameters_ty ?boot_sector ~input_message ~expected_storage ~kind
    ~message_kind =
  let commitment_period = 2 and challenge_window = 5 in
  let message_kind_s =
    match message_kind with `Internal -> "intern" | `External -> "extern"
  in
  let entrypoint_s = Option.value ~default:"default" entrypoint in
  let outbox_parameters_ty_s =
    Option.value ~default:"no_parameters_ty" outbox_parameters_ty
  in
  test_full_scenario
    ?supports
    ?regression
    ~hooks
    ?boot_sector
    ~parameters_ty:"bytes"
    ~kind
    ~commitment_period
    ~challenge_window
    {
      tags = ["outbox"; message_kind_s; entrypoint_s; outbox_parameters_ty_s];
      variant =
        Some
          (Format.sprintf
             "%s, entrypoint: %%%s, eager: %d, %s, %s"
             init_storage
             entrypoint_s
             earliness
             message_kind_s
             outbox_parameters_ty_s);
      description = "output exec";
    }
    ~uses:(fun _protocol -> [Constant.octez_codec])
  @@ fun protocol rollup_node sc_rollup _node client ->
  let* () = Sc_rollup_node.run rollup_node sc_rollup [] in
  let src = Constant.bootstrap1.public_key_hash in
  let src2 = Constant.bootstrap2.public_key_hash in
  let originate_target_contract () =
    let prg =
      Printf.sprintf
        {|
          {
            parameter (or (%s %%default) (%s %%aux));
            storage (%s :s);
            code
              {
                # Check that SENDER is the rollup address
                SENDER;
                PUSH address %S;
                ASSERT_CMPEQ;
                # Check that SOURCE is the implicit account used for executing
                # the outbox message.
                SOURCE;
                PUSH address %S;
                ASSERT_CMPEQ;
                UNPAIR;
                IF_LEFT
                  { SWAP ; DROP; NIL operation }
                  { SWAP ; DROP; NIL operation };
                PAIR;
              }
          }
        |}
        storage_ty
        storage_ty
        storage_ty
        sc_rollup
        src2
    in
    let* address =
      Client.originate_contract
        ~alias:"target"
        ~amount:(Tez.of_int 100)
        ~burn_cap:(Tez.of_int 100)
        ~src
        ~prg
        ~init:init_storage
        client
    in
    let* () = Client.bake_for_and_wait client in
    return address
  in
  let check_contract_execution address expected_storage =
    let* storage = Client.contract_storage address client in
    return
    @@ Check.(
         (String.trim storage = expected_storage)
           string
           ~error_msg:"Invalid contract storage: expecting '%R', got '%L'.")
  in
  let perform_rollup_execution_and_cement source_address target_address =
    let* payload = input_message protocol target_address in
    let* () =
      match payload with
      | `External payload ->
          send_text_messages ~hooks ~format:`Hex client [payload]
      | `Internal payload ->
          let payload = "0x" ^ payload in
          Client.transfer
            ~amount:Tez.(of_int 100)
            ~burn_cap:Tez.(of_int 100)
            ~storage_limit:100000
            ~giver:Constant.bootstrap1.alias
            ~receiver:source_address
            ~arg:(sf "Pair %s %S" payload sc_rollup)
            client
    in
    let blocks_to_wait =
      3 + (2 * commitment_period) + challenge_window - earliness
    in
    repeat blocks_to_wait @@ fun () -> Client.bake_for_and_wait client
  in
  let trigger_outbox_message_execution ?expected_l1_error address =
    let outbox_level = 5 in
    let parameters = "37" in
    let message_index = 0 in
    let check_expected_outbox () =
      let* outbox =
        Sc_rollup_node.RPC.call rollup_node
        @@ Sc_rollup_rpc.get_global_block_outbox ~outbox_level ()
      in
      Log.info "Outbox is %s" (JSON.encode outbox) ;
      match expected_error with
      | None ->
          let expected =
            JSON.parse ~origin:"trigger_outbox_message_execution"
            @@ Printf.sprintf
                 {|
              [ { "outbox_level": %d, "message_index": "%d",
                  "message":
                  { "transactions":
                      [ { "parameters": { "int": "%s" }%s,
                          "destination": "%s"%s } ]%s
                     } } ] |}
                 outbox_level
                 message_index
                 parameters
                 (match outbox_parameters_ty with
                 | None -> ""
                 | Some outbox_parameters_ty ->
                     Format.asprintf
                       {| , "parameters_ty" : { "prim": "%s"} |}
                       outbox_parameters_ty)
                 address
                 (match entrypoint with
                 | None -> ""
                 | Some entrypoint ->
                     Format.asprintf {| , "entrypoint" : "%s" |} entrypoint)
                 (Printf.sprintf
                    {|, "kind": "%s"|}
                    (Option.fold
                       ~none:"untyped"
                       ~some:(fun _ -> "typed")
                       outbox_parameters_ty))
          in
          Log.info "Expected is %s" (JSON.encode expected) ;
          assert (JSON.encode expected = JSON.encode outbox) ;
          let parameters_json = `O [("int", `String parameters)] in
          let batch =
            {
              destination = address;
              entrypoint;
              parameters = parameters_json;
              parameters_ty =
                (match outbox_parameters_ty with
                | Some json_value -> Some (`O [("prim", `String json_value)])
                | None -> None);
            }
          in
          let message_json =
            Sc_rollup_helpers.json_of_output_tx_batch [batch]
          in
          let* message =
            Codec.encode
              ~name:
                (Protocol.encoding_prefix protocol
                ^ ".smart_rollup.outbox.message")
              message_json
          in
          let* proof =
            Sc_rollup_node.RPC.call rollup_node
            @@ Sc_rollup_rpc.outbox_proof_single
                 ~message_index
                 ~outbox_level
                 ~message
                 ()
          in
          let* proof' =
            Sc_rollup_node.RPC.call rollup_node
            @@ Sc_rollup_rpc.outbox_proof_simple ~message_index ~outbox_level ()
          in
          (* Test outbox_proof command with/without input transactions. *)
          assert (proof' = proof) ;
          return proof
      | Some _ ->
          assert (JSON.encode outbox = "[]") ;
          return None
    in
    let* answer = check_expected_outbox () in
    match (answer, expected_error) with
    | Some _, Some _ -> assert false
    | None, None -> failwith "Unexpected error during proof generation"
    | None, Some _ -> unit
    | Some {commitment_hash; proof}, None -> (
        match expected_l1_error with
        | None ->
            let*! () =
              Client.Sc_rollup.execute_outbox_message
                ~hooks
                ~burn_cap:(Tez.of_int 10)
                ~rollup:sc_rollup
                ~src:src2
                ~commitment_hash
                ~proof
                client
            in
            Client.bake_for_and_wait client
        | Some msg ->
            let*? process =
              Client.Sc_rollup.execute_outbox_message
                ~hooks
                ~burn_cap:(Tez.of_int 10)
                ~rollup:sc_rollup
                ~src:src2
                ~commitment_hash
                ~proof
                client
            in
            Process.check_error ~msg process)
  in
  let* target_contract_address = originate_target_contract () in
  let* source_contract_address =
    originate_forward_smart_contract client protocol
  in
  let* () =
    perform_rollup_execution_and_cement
      source_contract_address
      target_contract_address
  in
  let* () = Client.bake_for_and_wait client in
  let* () =
    trigger_outbox_message_execution ?expected_l1_error target_contract_address
  in
  match expected_error with
  | None ->
      let* () =
        check_contract_execution target_contract_address expected_storage
      in
      unit
  | Some _ -> unit

let test_outbox_message ?supports ?regression ?expected_error ?expected_l1_error
    ~earliness ?entrypoint ?(init_storage = "0") ?(storage_ty = "int")
    ?(outbox_parameters = "37") ?outbox_parameters_ty ~kind ~message_kind =
  let wrap payload =
    match message_kind with
    | `Internal -> `Internal payload
    | `External -> `External payload
  in
  let boot_sector, input_message, expected_storage =
    match kind with
    | "arith" ->
        let input_message _protocol contract_address =
          let payload =
            Printf.sprintf
              "%s %s%s"
              outbox_parameters
              contract_address
              (match entrypoint with Some e -> "%" ^ e | None -> "")
          in
          let payload = hex_encode payload in
          return @@ wrap payload
        in
        (None, input_message, outbox_parameters)
    | "wasm_2_0_0" ->
        let bootsector = read_kernel "echo" in
        let input_message protocol contract_address =
          let parameters_json = `O [("int", `String outbox_parameters)] in
          let transaction =
            Sc_rollup_helpers.
              {
                destination = contract_address;
                entrypoint;
                parameters = parameters_json;
                parameters_ty =
                  (match outbox_parameters_ty with
                  | Some json_value -> Some (`O [("prim", `String json_value)])
                  | None -> None);
              }
          in
          let* answer =
            Codec.encode
              ~name:
                (Protocol.encoding_prefix protocol
                ^ ".smart_rollup.outbox.message")
              (Sc_rollup_helpers.json_of_output_tx_batch [transaction])
          in
          return (wrap (String.trim answer))
        in
        ( Some bootsector,
          input_message,
          if Option.is_none expected_l1_error then outbox_parameters
          else init_storage )
    | _ ->
        (* There is no other PVM in the protocol. *)
        assert false
  in
  test_outbox_message_generic
    ?supports
    ?regression
    ?expected_error
    ?expected_l1_error
    ~earliness
    ?entrypoint
    ?outbox_parameters_ty
    ?boot_sector
    ~init_storage
    ~storage_ty
    ~input_message
    ~expected_storage
    ~message_kind
    ~kind

let test_outbox_message protocols ~kind =
  let test (expected_error, earliness, entrypoint, message_kind) =
    test_outbox_message
      ?expected_error
      ~earliness
      ?entrypoint
      ~message_kind
      protocols
      ~kind ;
    (* arith does not support, yet, the typed outbox messages *)
    if kind <> "arith" then
      test_outbox_message
        ~supports:(Protocol.From_protocol 17)
        ?expected_error
        ~earliness
        ?entrypoint
        ~message_kind
        ~outbox_parameters_ty:"int"
        protocols
        ~kind
  in
  List.iter
    test
    [
      (None, 0, None, `Internal);
      (None, 0, Some "aux", `Internal);
      (Some (Base.rex ".*Invalid claim about outbox"), 5, None, `Internal);
      (Some (Base.rex ".*Invalid claim about outbox"), 5, Some "aux", `Internal);
      (None, 0, None, `External);
      (None, 0, Some "aux", `External);
      (Some (Base.rex ".*Invalid claim about outbox"), 5, None, `External);
      (Some (Base.rex ".*Invalid claim about outbox"), 5, Some "aux", `External);
    ] ;
  if kind <> "arith" then (
    (* wrong type for the parameters *)
    test_outbox_message
      ~expected_l1_error:
        (Base.rex "A data expression was invalid for its expected type.")
      ~supports:(Protocol.From_protocol 17)
      ~earliness:0
      ~message_kind:`Internal
      ~outbox_parameters_ty:"string"
      protocols
      ~kind ;
    test_outbox_message
      ~expected_l1_error:
        (Base.rex ".*or a parameter was supplied of the wrong type")
      ~supports:(Protocol.From_protocol 17)
      ~earliness:0
      ~message_kind:`Internal
      ~init_storage:{|"word"|}
      ~storage_ty:"string"
      ~outbox_parameters_ty:"int"
      protocols
      ~kind)

let test_rpcs ~kind
    ?(boot_sector = Sc_rollup_helpers.default_boot_sector_of ~kind) =
  test_full_scenario
    ~regression:true
    ~hooks
    ~kind
    ~boot_sector
    ~whitelist_enable:true
    {
      tags = ["rpc"; "api"];
      variant = None;
      description = "RPC API should work and be stable";
    }
  @@ fun protocol sc_rollup_node sc_rollup node client ->
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* _level = Sc_rollup_node.wait_sync ~timeout:30. sc_rollup_node in
  (* Smart rollup address endpoint test *)
  let* sc_rollup_address =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_smart_rollup_address ()
  in
  Check.((sc_rollup_address = sc_rollup) string)
    ~error_msg:"SC rollup address of node is %L but should be %R" ;
  let n = 15 in
  let batch_size = 5 in
  let* hashes =
    send_messages_batcher
      ~rpc_hooks:Tezos_regression.rpc_hooks
      ~batch_size
      n
      client
      sc_rollup_node
  in
  Check.((List.length hashes = n * batch_size) int)
    ~error_msg:"Injected %L messages but should have injected %R" ;
  (* Head block hash endpoint test *)
  let* level = Node.get_level node in
  let* _ = Sc_rollup_node.wait_for_level ~timeout:3.0 sc_rollup_node level in
  let* l1_block_hash = Client.RPC.call client @@ RPC.get_chain_block_hash () in
  let* l2_block_hash =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_hash ()
  in
  let l2_block_hash = JSON.as_string l2_block_hash in
  Check.((l1_block_hash = l2_block_hash) string)
    ~error_msg:"Head on L1 is %L where as on L2 it is %R" ;
  let* l1_block_hash_5 =
    Client.RPC.call client @@ RPC.get_chain_block_hash ~block:"5" ()
  in
  let* l2_block_hash_5 =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_hash ~block:"5" ()
  in
  let l2_block_hash_5 = JSON.as_string l2_block_hash_5 in
  Check.((l1_block_hash_5 = l2_block_hash_5) string)
    ~error_msg:"Block 5 on L1 is %L where as on L2 it is %R" ;
  let* l2_finalied_block_level =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_level ~block:"finalized" ()
  in
  let l2_finalied_block_level = JSON.as_int l2_finalied_block_level in
  Check.((l2_finalied_block_level = level - 2) int)
    ~error_msg:"Finalized block is %L but should be %R" ;
  let* l2_num_messages =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_num_messages ()
  in
  (* There are always 3 extra messages inserted by the protocol in the inbox. *)
  let nb_protocol_messages = 3 in
  let l2_num_messages = JSON.as_int l2_num_messages in
  Check.((l2_num_messages = batch_size + nb_protocol_messages) int)
    ~error_msg:"Number of messages of head is %L but should be %R" ;

  (* Durable value storage RPC tests *)
  let* () =
    match kind with
    | "arith" ->
        (* Make sure we neither have WASM nor Arith PVM endpoint in arith PVM *)
        let* response =
          Sc_rollup_node.RPC.call_raw sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:"wasm_2_0_0"
               ~operation:Sc_rollup_rpc.Value
               ~key:"/readonly/wasm_version"
               ()
        in
        let* () = return @@ RPC_core.check_string_response ~code:404 response in
        let* response =
          Sc_rollup_node.RPC.call_raw sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:"arith"
               ~operation:Sc_rollup_rpc.Value
               ~key:"/readonly/wasm_version"
               ()
        in
        return @@ RPC_core.check_string_response ~code:404 response
    | "wasm_2_0_0" ->
        let* wasm_boot_sector =
          Sc_rollup_node.RPC.call sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:kind
               ~operation:Sc_rollup_rpc.Value
               ~key:"/kernel/boot.wasm"
               ()
        in
        Check.(
          (wasm_boot_sector = Some Constant.wasm_echo_kernel_boot_sector)
            (option string))
          ~error_msg:"Encoded WASM kernel is %L but should be %R" ;
        let* nonexisting_wasm_boot_sector =
          Sc_rollup_node.RPC.call sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:kind
               ~operation:Sc_rollup_rpc.Value
               ~key:"/kernel/boot.wasm2"
               ()
        in
        Check.((nonexisting_wasm_boot_sector = None) (option string))
          ~error_msg:"Encoded WASM kernel is %L but should be %R" ;

        let* wasm_version_hex_opt =
          Sc_rollup_node.RPC.call sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:kind
               ~operation:Sc_rollup_rpc.Value
               ~key:"/readonly/wasm_version"
               ()
        in
        let wasm_version =
          Option.map
            (fun wasm_version_hex -> Hex.to_string (`Hex wasm_version_hex))
            wasm_version_hex_opt
        in
        Check.(
          (wasm_version = Some (default_wasm_pvm_revision protocol))
            (option string))
          ~error_msg:"Decoded WASM version is %L but should be %R" ;

        let* wasm_version_len =
          Sc_rollup_node.RPC.call sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:kind
               ~operation:Sc_rollup_rpc.Length
               ~key:"/readonly/wasm_version"
               ()
        in
        Check.(
          (wasm_version_len
          = Some
              (default_wasm_pvm_revision protocol
              |> String.length |> Int64.of_int))
            (option int64))
          ~error_msg:"WASM version value length is %L but should be %R" ;

        let* kernel_subkeys =
          Sc_rollup_node.RPC.call sc_rollup_node ~rpc_hooks
          @@ Sc_rollup_rpc.get_global_block_durable_state_value
               ~pvm_kind:kind
               ~operation:Sc_rollup_rpc.Subkeys
               ~key:"/readonly/kernel"
               ()
        in
        Check.((kernel_subkeys = ["boot.wasm"; "env"]) (list string))
          ~error_msg:"The key's subkeys are %L but should be %R" ;
        return ()
    | _ -> failwith "incorrect kind"
  in
  let* _status =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_status ()
  in
  let* _ticks =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_ticks ()
  in
  let* _state_hash =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ()
  in
  let* _outbox =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_outbox
         ~outbox_level:l2_finalied_block_level
         ()
  in
  let* _head =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_tezos_head ()
  in
  let* _level =
    Sc_rollup_node.RPC.call ~rpc_hooks sc_rollup_node
    @@ Sc_rollup_rpc.get_global_tezos_level ()
  in
  let* l2_block =
    Sc_rollup_node.RPC.call sc_rollup_node @@ Sc_rollup_rpc.get_global_block ()
  in
  let l2_block_hash' = JSON.(l2_block |-> "block_hash" |> as_string) in
  Check.((l2_block_hash' = l2_block_hash) string)
    ~error_msg:"L2 head is from full block is %L but should be %R" ;
  if Protocol.number protocol >= 018 then (
    let whitelist = [Constant.bootstrap1.public_key_hash] in
    let* _, sc_rollup =
      setup_rollup ~alias:"rollup2" ~kind ~whitelist node client
    in
    let* retrieved_whitelist =
      Client.RPC.call client
      @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_whitelist
           sc_rollup
    in
    Check.(
      is_true
        (match retrieved_whitelist with
        | Some l -> List.equal String.equal l whitelist
        | _ -> false))
      ~error_msg:"no whitelist found." ;
    unit)
  else unit

let test_messages_processed_by_commitment ~kind =
  test_full_scenario
    {
      variant = None;
      tags = ["commitment"; "evaluation"];
      description = "checks messages processed during a commitment period";
    }
    ~kind
  @@ fun _protocol sc_rollup_node sc_rollup _node client ->
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup [] in
  let* {commitment_period_in_blocks; _} = get_sc_rollup_constants client in
  let* genesis_info =
    Client.RPC.call ~hooks client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let store_commitment_level =
    init_level + commitment_period_in_blocks + block_finality_time
  in
  (* Bake enough blocks so [sc_rollup_node] posts a commitment. *)
  let* () =
    repeat (commitment_period_in_blocks + block_finality_time) (fun () ->
        Client.bake_for_and_wait client)
  in
  (* Wait until the [sc_rollup_node] store the commitment. *)
  let* (_ : int) =
    Sc_rollup_node.wait_for_level
      ~timeout:3.
      sc_rollup_node
      store_commitment_level
  in
  let* {commitment = {inbox_level; _}; hash = _} =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_last_stored_commitment ()
  in
  let* current_level =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_current_level
         ~block:(string_of_int inbox_level)
         ()
  in
  Check.((current_level = inbox_level) int)
    ~error_msg:
      "The rollup node should process all the levels of a commitment period, \
       expected %L, got %R" ;
  unit

let test_recover_bond_of_stakers =
  test_l1_scenario
    ~regression:true
    ~hooks
    ~boot_sector:""
    ~kind:"arith"
    ~challenge_window:10
    ~commitment_period:10
    {
      variant = None;
      tags = ["commitment"; "staker"; "recover"];
      description = "recover bond of stakers";
    }
  @@ fun protocol sc_rollup _tezos_node tezos_client ->
  let* {
         commitment_period_in_blocks;
         challenge_window_in_blocks;
         stake_amount;
         _;
       } =
    get_sc_rollup_constants tezos_client
  in
  let* predecessor, level =
    last_cemented_commitment_hash_with_level ~sc_rollup tezos_client
  in
  let staker1 = Constant.bootstrap1 in
  let staker2 = Constant.bootstrap2 in
  (* Bake enough to publish. *)
  let* () =
    repeat (commitment_period_in_blocks + 1) (fun () ->
        Client.bake_for_and_wait tezos_client)
  in
  (* Both accounts stakes on a commitment. *)
  let* _, commitment1 =
    forge_and_publish_commitment
      ~inbox_level:(level + commitment_period_in_blocks)
      ~predecessor
      ~sc_rollup
      ~src:staker1.public_key_hash
      tezos_client
  in
  let* _, commitment2 =
    forge_and_publish_commitment
      ~inbox_level:(level + commitment_period_in_blocks)
      ~predecessor
      ~sc_rollup
      ~src:staker2.public_key_hash
      tezos_client
  in
  assert (commitment1 = commitment2) ;
  (* Bake enough to cement. *)
  let* () =
    repeat challenge_window_in_blocks (fun () ->
        Client.bake_for_and_wait tezos_client)
  in
  (* Cement. *)
  let* () =
    cement_commitment protocol tezos_client ~sc_rollup ~hash:commitment1
  in

  (* Staker1 withdraw its stake. *)
  let* () =
    attempt_withdraw_stake
      ~check_liquid_balance:false
      ~sc_rollup
      ~sc_rollup_stake_amount:(Tez.to_mutez stake_amount)
      ~src:staker1.public_key_hash
      ~staker:staker1.public_key_hash
      tezos_client
  in
  (* Staker1 withdraw the stake of staker2. *)
  let* () =
    attempt_withdraw_stake
      ~check_liquid_balance:false
      ~sc_rollup
      ~sc_rollup_stake_amount:(Tez.to_mutez stake_amount)
      ~src:staker1.public_key_hash
      ~staker:staker2.public_key_hash
      tezos_client
  in
  unit

let test_injector_auto_discard =
  test_full_scenario
    {
      variant = None;
      tags = ["injector"];
      description = "Injector discards repeatedly failing operations";
    }
    ~kind:"arith"
  @@ fun _protocol _sc_rollup_node sc_rollup tezos_node client ->
  let* operator = Client.gen_and_show_keys client in
  (* Change operator and only batch messages *)
  let sc_rollup_node =
    Sc_rollup_node.create
      Batcher
      tezos_node
      ~base_dir:(Client.base_dir client)
      ~operators:[(Sc_rollup_node.Batching, operator.alias)]
  in
  let nb_attempts = 5 in
  let* () =
    Sc_rollup_node.run
      ~event_level:`Debug
      sc_rollup_node
      sc_rollup
      [Injector_attempts nb_attempts]
  in
  let monitor_injector_queue =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "number_of_operations_in_queue.v0"
      (fun event ->
        let nb = JSON.(event |-> "number_of_operations" |> as_int) in
        Log.info "Injector: %d operations in queue" nb ;
        (* Because we send one batch of messages by block to the injector, and
           each operation is allowed to fail [nb_attempts] times, we should have
           at most [nb_attempts] in the queue. *)
        Check.((nb <= nb_attempts) int)
          ~error_msg:
            "There are %L add messages operations in the injector queue but \
             there should be at most %R" ;
        None)
  in
  let n = 65 in
  let batch_size = 3 in
  let* _hashes =
    send_messages_batcher
      ~rpc_hooks:Tezos_regression.rpc_hooks
      ~batch_size
      n
      client
      sc_rollup_node
  in
  Lwt.cancel monitor_injector_queue ;
  unit

let test_arg_boot_sector_file ~kind =
  let hex_if_wasm s =
    match kind with "wasm_2_0_0" -> Hex.(of_string s |> show) | _ -> s
  in
  let boot_sector =
    hex_if_wasm "Nantes aurait été un meilleur nom de protocol"
  in
  test_full_scenario
    ~supports:(Protocol.From_protocol 018)
    ~kind
    ~boot_sector
    {
      variant = None;
      tags = ["node"; "boot_sector"; "boot_sector_file"];
      description = "Rollup node uses argument boot sector file";
    }
  @@ fun _protocol rollup_node rollup _node client ->
  let invalid_boot_sector =
    hex_if_wasm "Nairobi est un bien meilleur nom de protocol que Nantes"
  in
  let invalid_boot_sector_file =
    Filename.temp_file "invalid-boot-sector" ".hex"
  in
  let () = write_file invalid_boot_sector_file ~contents:invalid_boot_sector in
  let valid_boot_sector_file = Filename.temp_file "valid-boot-sector" ".hex" in
  let () = write_file valid_boot_sector_file ~contents:boot_sector in
  (* Starts the rollup node with an invalid boot sector. Asserts that the
     node fails with an invalid genesis state. *)
  let* () =
    Sc_rollup_node.run
      ~wait_ready:false
      rollup_node
      rollup
      [Boot_sector_file invalid_boot_sector_file]
  and* () =
    Sc_rollup_node.check_error
      ~exit_code:1
      ~msg:
        (rex
           "Genesis commitment computed (.*) is not equal to the rollup \
            genesis (.*) commitment.*")
      rollup_node
  in
  (* Starts the rollup node with a valid boot sector. Asserts that the node
     works as expected by processing blocks. *)
  let* () =
    Sc_rollup_node.run
    (* the restart is needed because the node and/or tezt daemon
       might not fully stoped yet. Another solution would be to have
       a sleep but it's more uncertain. *)
      ~restart:true
      rollup_node
      rollup
      [Boot_sector_file valid_boot_sector_file]
  in
  let* () = Client.bake_for_and_wait client in
  let* _ = Sc_rollup_node.wait_sync ~timeout:10. rollup_node in
  unit

let test_bootstrap_smart_rollup_originated =
  register_test
    ~supports:(From_protocol 018)
    ~__FILE__
    ~tags:["bootstrap"; "parameter"]
    ~title:"Bootstrap smart rollups are listed"
  @@ fun protocol ->
  let bootstrap_arith : Protocol.bootstrap_smart_rollup =
    {
      address = "sr1RYurGZtN8KNSpkMcCt9CgWeUaNkzsAfXf";
      pvm_kind = "arith";
      boot_sector = "";
      parameters_ty = `O [("prim", `String "unit")];
      whitelist = None;
    }
  in
  let bootstrap_wasm : Protocol.bootstrap_smart_rollup =
    {
      address = "sr163Lv22CdE8QagCwf48PWDTquk6isQwv57";
      pvm_kind = "wasm_2_0_0";
      boot_sector = "";
      parameters_ty = `O [("prim", `String "unit")];
      whitelist = None;
    }
  in
  let bootstrap_smart_rollups = [bootstrap_arith; bootstrap_wasm] in
  let* _node, client = setup_l1 ~bootstrap_smart_rollups protocol in
  let* rollups =
    Client.RPC.call client @@ RPC.get_chain_block_context_smart_rollups_all ()
  in
  let bootstrap_smart_rollups_addresses =
    List.map (fun Protocol.{address; _} -> address) bootstrap_smart_rollups
  in
  Check.(
    (rollups = bootstrap_smart_rollups_addresses)
      (list string)
      ~error_msg:"Expected %R bootstrapped smart rollups, got %L") ;
  unit

let test_bootstrap_private_smart_rollup_originated =
  register_test
    ~supports:(From_protocol 018)
    ~__FILE__
    ~tags:["bootstrap"; "parameter"; "private"]
    ~title:"Bootstrap private smart rollups are private"
  @@ fun protocol ->
  let whitelist = Some [Constant.bootstrap1.public_key_hash] in
  let bootstrap_arith : Protocol.bootstrap_smart_rollup =
    {
      address = "sr1RYurGZtN8KNSpkMcCt9CgWeUaNkzsAfXf";
      pvm_kind = "arith";
      boot_sector = "";
      parameters_ty = `O [("prim", `String "unit")];
      whitelist;
    }
  in
  let bootstrap_smart_rollups = [bootstrap_arith] in
  let* _node, client =
    setup_l1 ~bootstrap_smart_rollups ~whitelist_enable:true protocol
  in
  let* found_whitelist =
    Client.RPC.call client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_whitelist
         bootstrap_arith.address
  in
  Check.(
    (whitelist = found_whitelist)
      (option (list string))
      ~error_msg:"Expected %R whitelist for bootstrapped smart rollups , got %L") ;
  unit

let test_rollup_node_missing_preimage_exit_at_initialisation =
  register_test
    ~supports:(From_protocol 016)
    ~__FILE__
    ~tags:["node"; "preimage"; "boot_sector"]
    ~uses:(fun _protocol ->
      Constant.
        [octez_smart_rollup_node; smart_rollup_installer; Constant.WASM.echo])
    ~title:
      "Rollup node exit if at initialisation, there is one or multiple \
       preimage(s) missing."
  @@ fun protocol ->
  let* node, client = setup_l1 protocol in
  let rollup_node =
    Sc_rollup_node.create
      ~base_dir:(Client.base_dir client)
      ~default_operator:Constant.bootstrap1.alias
      Operator
      node
  in
  let* {boot_sector; _} =
    (* The preimages will be saved in the rollup node's data directory
       ROLLUP_NODE_DATA_DIR, whereas the rollup node will try to look
       for the preimages in ROLLUP_NODE_DATA_DIR/wasm_2_0_0. *)
    let preimages_dir = Sc_rollup_node.data_dir rollup_node in
    Sc_rollup_helpers.prepare_installer_kernel ~preimages_dir Constant.WASM.echo
  in
  let* rollup_address =
    originate_sc_rollup
      ~kind:"wasm_2_0_0"
      ~boot_sector
      ~src:Constant.bootstrap1.alias
      client
  in
  let* _ = Sc_rollup_node.config_init rollup_node rollup_address in
  let* () = Sc_rollup_node.run rollup_node rollup_address [] in
  let* () = Client.bake_for_and_wait client
  and* () =
    Sc_rollup_node.check_error
      ~msg:(rex "Could not open file containing preimage of reveal hash")
      rollup_node
  in
  Lwt.return_unit

let test_private_rollup_whitelist ?check_error ~regression ~description
    ~commit_publisher ~whitelist =
  test_l1_scenario
    ~regression
    ~supports:(From_protocol 018)
    ~whitelist_enable:true
    ~whitelist
    ~src:Constant.bootstrap1.public_key_hash
    {variant = None; tags = ["whitelist"]; description}
    ~kind:"arith"
  @@ fun _protocol sc_rollup _node client ->
  let* () = Client.bake_for_and_wait client in
  let* predecessor, inbox_level =
    last_cemented_commitment_hash_with_level ~sc_rollup client
  in
  let _, client_runnable =
    forge_and_publish_commitment_return_runnable
      ~predecessor
      ~inbox_level
      ~sc_rollup
      ~src:commit_publisher
      client
  in
  let client_process = client_runnable.value in
  match check_error with
  | Some check -> check client_process
  | None -> return ()

let test_private_rollup_whitelisted_staker =
  test_private_rollup_whitelist
    ~regression:true
    ~whitelist:[Constant.bootstrap1.public_key_hash]
    ~commit_publisher:Constant.bootstrap1.alias
    ~description:"Whitelisted staker can publish a commitment"

let test_private_rollup_non_whitelisted_staker =
  test_private_rollup_whitelist
    ~regression:false
    ~whitelist:[Constant.bootstrap2.public_key_hash]
    ~commit_publisher:Constant.bootstrap1.alias
    ~description:"Non-whitelisted staker cannot publish a commitment"
    ~check_error:
      (Process.check_error
         ~msg:
           (rex
              "The rollup is private and the submitter of the commitment is \
               not present in the whitelist"))

let test_private_rollup_node_publish_in_whitelist =
  let commitment_period = 3 in
  test_full_scenario
    ~supports:(From_protocol 018)
    ~whitelist_enable:true
    ~whitelist:[Constant.bootstrap1.public_key_hash]
    ~operator:Constant.bootstrap1.alias
    ~commitment_period
    {
      variant = None;
      tags = ["whitelist"];
      description =
        "Rollup node publishes commitment if the operator is in the whitelist";
    }
    ~kind:"arith"
  @@ fun _protocol rollup_node sc_rollup _tezos_node tezos_client ->
  let* () = Sc_rollup_node.run ~event_level:`Debug rollup_node sc_rollup [] in
  let levels = commitment_period in
  Log.info "Baking at least %d blocks for commitment of first message" levels ;
  let* _new_level =
    bake_until_lpc_updated ~at_least:levels ~timeout:5. tezos_client rollup_node
  in
  bake_levels levels tezos_client

let test_private_rollup_node_publish_not_in_whitelist =
  let operator = Constant.bootstrap1.alias in
  test_full_scenario
    ~supports:(From_protocol 018)
    ~whitelist_enable:true
    ~whitelist:[Constant.bootstrap2.public_key_hash]
    ~operator
    ~mode:Operator
    {
      variant = None;
      tags = ["whitelist"; "bla"];
      description =
        "Rollup node fails to start if the operator is not in the whitelist";
    }
    ~kind:"arith"
  @@ fun _protocol rollup_node sc_rollup _tezos_node _client ->
  let* () = Sc_rollup_node.run ~wait_ready:false rollup_node sc_rollup []
  and* () =
    Sc_rollup_node.check_error
      rollup_node
      ~exit_code:1
      ~msg:(rex ".*The operator is not in the whitelist.*")
  in
  unit

let test_rollup_whitelist_update ~kind =
  let commitment_period = 2 and challenge_window = 5 in
  let whitelist = [Constant.bootstrap1.public_key_hash] in
  test_full_scenario
    {
      variant = None;
      tags = ["private"; "whitelist"; "update"];
      description = "kernel update whitelist";
    }
    ~uses:(fun _protocol -> [Constant.octez_codec])
    ~kind
    ~whitelist_enable:true
    ~whitelist
    ~supports:(From_protocol 018)
    ~commitment_period
    ~challenge_window
    ~operator:Constant.bootstrap1.public_key_hash
  @@ fun protocol rollup_node rollup_addr node client ->
  let encode_whitelist_msg whitelist =
    Codec.encode
      ~name:(Protocol.encoding_prefix protocol ^ ".smart_rollup.outbox.message")
      (`O
        [
          ("whitelist", `A (List.map (fun pkh -> `String pkh) whitelist));
          ("kind", `String "whitelist_update");
        ])
  in
  let send_whitelist_then_bake_until_exec encoded_whitelist_msgs =
    let* _res =
      send_messages_then_bake_until_rollup_node_execute_output_message
        ~commitment_period
        ~challenge_window
        client
        rollup_node
        encoded_whitelist_msgs
    in
    unit
  in
  let last_published_commitment_hash rollup_node =
    let* Sc_rollup_rpc.{commitment_and_hash = {commitment; _}; _} =
      Sc_rollup_node.RPC.call rollup_node
      @@ Sc_rollup_rpc.get_local_last_published_commitment ()
    in
    return commitment
  in
  let* () = Sc_rollup_node.run ~event_level:`Debug rollup_node rollup_addr [] in
  (* bake until the first commitment is published. *)
  let* _level =
    bake_until_lpc_updated ~at_least:commitment_period client rollup_node
  in
  let* () =
    let* commitment = last_published_commitment_hash rollup_node in
    (* Bootstrap2 attempts to publish a commitments while not present in the whitelist. *)
    let*? process =
      publish_commitment
        ~src:Constant.bootstrap2.alias
        ~commitment
        client
        rollup_addr
    in
    let* output_err =
      Process.check_and_read_stderr ~expect_failure:true process
    in
    (* The attempt at publishing a commitment fails. *)
    Check.(
      (output_err
      =~ rex
           ".*The rollup is private and the submitter of the commitment is not \
            present in the whitelist.*")
        ~error_msg:"Expected output \"%L\" to match expression \"%R\".") ;
    unit
  in
  let* () =
    let* encoded_whitelist_update =
      encode_whitelist_msg
        [
          Constant.bootstrap1.public_key_hash;
          Constant.bootstrap2.public_key_hash;
        ]
    in
    send_whitelist_then_bake_until_exec [encoded_whitelist_update]
  in
  let* () =
    (* Bootstrap2 now can publish a commitments as it's present in the whitelist. *)
    let* commitment = last_published_commitment_hash rollup_node in
    let*! () =
      publish_commitment
        ~src:Constant.bootstrap2.alias
        ~commitment
        client
        rollup_addr
    in
    let* () = Client.bake_for_and_wait client in
    unit
  in
  Log.info
    "submits two whitelist update in one inbox level. Only the second update \
     is executed by the rollup node." ;
  let* () =
    let* encoded_whitelist_update1 =
      encode_whitelist_msg [Constant.bootstrap3.public_key_hash]
    in
    let* encoded_whitelist_update2 =
      Codec.encode
        ~name:
          (Protocol.encoding_prefix protocol ^ ".smart_rollup.outbox.message")
        (`O [("kind", `String "whitelist_update")])
    in
    send_whitelist_then_bake_until_exec
      [encoded_whitelist_update1; encoded_whitelist_update2]
  in
  let* commitment = last_published_commitment_hash rollup_node in
  (* now an adress that was not previously in the whitelist can
     publish a commitment *)
  let*! () =
    publish_commitment
      ~src:Constant.bootstrap4.alias
      ~commitment
      client
      rollup_addr
  in
  let* () = Client.bake_for_and_wait client in
  Log.info
    "Start a new rollup node with an operator that was not in the whitelist to \
     ensure it can catch up" ;
  let rollup_node2 =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client)
      ~default_operator:Constant.bootstrap3.alias
  in
  let* () = Sc_rollup_node.run rollup_node2 rollup_addr [] in
  let* _level = Sc_rollup_node.wait_sync ~timeout:30. rollup_node2 in
  unit

let test_rollup_whitelist_outdated_update ~kind =
  let commitment_period = 2 and challenge_window = 5 in
  let whitelist =
    [Constant.bootstrap1.public_key_hash; Constant.bootstrap2.public_key_hash]
  in
  test_full_scenario
    {
      variant = None;
      tags = ["whitelist"];
      description = "outdated whitelist update";
    }
    ~uses:(fun _protocol -> [Constant.octez_codec])
    ~kind
    ~whitelist_enable:true
    ~whitelist
    ~supports:(From_protocol 018)
    ~commitment_period
    ~challenge_window
  @@ fun protocol rollup_node rollup_addr _node client ->
  let* () = Sc_rollup_node.run ~event_level:`Debug rollup_node rollup_addr [] in
  let* payload =
    Codec.encode
      ~name:(Protocol.encoding_prefix protocol ^ ".smart_rollup.outbox.message")
      (`O
        [
          ("whitelist", `A [`String Constant.bootstrap1.public_key_hash]);
          ("kind", `String "whitelist_update");
        ])
  in
  let* payload2 =
    Codec.encode
      ~name:(Protocol.encoding_prefix protocol ^ ".smart_rollup.outbox.message")
      (`O
        [
          ( "whitelist",
            `A
              [
                `String Constant.bootstrap1.public_key_hash;
                `String Constant.bootstrap2.public_key_hash;
              ] );
          ("kind", `String "whitelist_update");
        ])
  in
  (* Execute whitelist update with outdated message index. *)
  let* _hash, outbox_level, message_index =
    send_messages_then_bake_until_rollup_node_execute_output_message
      ~commitment_period
      ~challenge_window
      client
      rollup_node
      [payload; payload2]
  in
  Check.((message_index = 1) int)
    ~error_msg:"Executed output message of index %L expected %R." ;
  let* {commitment_hash; proof} =
    get_outbox_proof rollup_node ~__LOC__ ~message_index:0 ~outbox_level
  in
  let {value = process; _} =
    Client.Sc_rollup.execute_outbox_message
      ~hooks
      ~burn_cap:(Tez.of_int 10)
      ~fee:(Tez.of_mutez_int 1498)
      ~rollup:rollup_addr
      ~src:Constant.bootstrap3.alias
      ~commitment_hash
      ~proof
      client
  in
  let* () =
    Process.check_error
      ~msg:(rex ".*Outdated whitelist update: got message index.*")
      process
  in

  (* Execute whitelist update with outdated outbox level. *)
  let* _hash, _outbox_level, _message_index =
    send_messages_then_bake_until_rollup_node_execute_output_message
      ~commitment_period
      ~challenge_window
      client
      rollup_node
      [payload; payload2]
  in
  let* {commitment_hash; proof} =
    get_outbox_proof rollup_node ~__LOC__ ~message_index ~outbox_level
  in
  let {value = process; _} =
    Client.Sc_rollup.execute_outbox_message
      ~hooks
      ~burn_cap:(Tez.of_int 10)
      ~fee:(Tez.of_mutez_int 1498)
      ~rollup:rollup_addr
      ~src:Constant.bootstrap3.alias
      ~commitment_hash
      ~proof
      client
  in
  Process.check_error
    ~msg:(rex ".*Outdated whitelist update: got outbox level.*")
    process

(** This test uses the rollup node, first it is running in an Operator
    mode, it bakes some blocks, then terminate. Then we restart the
    node in a Bailout mode, initiate the recover_bond process, and
    make sure that no new commitments are published. *)
let bailout_mode_not_publish ~kind =
  let operator = Constant.bootstrap5.public_key_hash in
  let commitment_period = 5 in
  let challenge_window = 5 in
  test_full_scenario
    {
      tags = ["node"; "mode"; "bailout"];
      variant = None;
      description = "rollup node - bailout mode does not publish";
    }
    ~kind
    ~operator
    ~mode:Operator
    ~challenge_window
    ~commitment_period
  @@ fun _protocol sc_rollup_node sc_rollup _tezos_node tezos_client ->
  (* Run the rollup node in Operator mode, bake some blocks until
     a commitment is published *)
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let* _level =
    bake_until_lpc_updated
      ~at_least:commitment_period
      tezos_client
      sc_rollup_node
  in
  let* published_commitment_before =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_local_last_published_commitment ()
  in
  let* staked_on_commitment =
    get_staked_on_commitment ~sc_rollup ~staker:operator tezos_client
  in
  Log.info "Check that the LPC is equal to the staked commitment onchain." ;
  let () =
    Check.(
      published_commitment_before.commitment_and_hash.hash
      = staked_on_commitment)
      Check.string
      ~error_msg:"Last published commitment is not latest commitment staked on."
  in
  (* Terminate the rollup of Operator mode and restart it with the Bailout mode *)
  let* () =
    Sc_rollup_node.run
      ~restart:true
      ~event_level:`Debug
      sc_rollup_node
      sc_rollup
      []
      ~mode:Bailout
  in
  (* The challenge window is neded to compute the correct number of block before
     cementation, we also add 2 times of commitment period to make sure
     no commit are published. *)
  let* () =
    repeat
      ((2 * commitment_period) + challenge_window)
      (fun () -> Client.bake_for_and_wait tezos_client)
  and* () =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "smart_rollup_node_recover_bond.v0"
      (Fun.const (Some ()))
  and* () =
    Sc_rollup_node.wait_for
      sc_rollup_node
      "smart_rollup_node_daemon_exit_bailout_mode.v0"
      (Fun.const (Some ()))
  and* exit_error = Sc_rollup_node.wait sc_rollup_node in
  let* lcc_hash, _level =
    Sc_rollup_helpers.last_cemented_commitment_hash_with_level
      ~sc_rollup
      tezos_client
  in
  Log.info "Check the LCC is the same." ;
  let () =
    Check.(lcc_hash = published_commitment_before.commitment_and_hash.hash)
      Check.string
      ~error_msg:
        "Published commitment is not the same as the cemented commitment hash."
  in
  Log.info
    "The node has submitted the recover_bond operation, and the operator is no \
     longer staked." ;
  let* frozen_balance =
    Client.RPC.call tezos_client
    @@ RPC.get_chain_block_context_contract_frozen_bonds ~id:operator ()
  in
  let () =
    Check.(
      (Tez.to_mutez frozen_balance = 0)
        int
        ~error_msg:
          "The operator should not have a stake nor holds a frozen balance.")
  in
  match exit_error with
  | WEXITED 0 -> unit
  | _ -> failwith "rollup node did not stop gracefully"

let custom_mode_empty_operation_kinds ~kind =
  test_l1_scenario
    ~kind
    {
      variant = None;
      tags = ["mode"; "custom"];
      description = "custom mode has empty operation kinds";
    }
    ~uses:(fun _protocol -> [Constant.octez_smart_rollup_node])
  @@ fun _protocol sc_rollup tezos_node tezos_client ->
  let sc_rollup_node =
    Sc_rollup_node.create
      (Custom [])
      tezos_node
      ~base_dir:(Client.base_dir tezos_client)
      ~default_operator:Constant.bootstrap1.alias
  in
  let* () = Sc_rollup_node.run ~wait_ready:false sc_rollup_node sc_rollup []
  and* () =
    Sc_rollup_node.check_error
      sc_rollup_node
      ~exit_code:1
      ~msg:(rex "Operation kinds for custom mode are empty.")
  in
  unit

(* adds multiple batcher keys for a rollup node runs in batcher mode
   and make sure all keys are used to sign batches and injected in a
   block. *)
let test_multiple_batcher_key ~kind =
  test_l1_scenario
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/6650

     also might be related to https://gitlab.com/tezos/tezos/-/issues/3014

     Test is flaky without rpc_external:false and it seems to be
     related to this issue. When investigating it seems that the sink
     used by the octez node has a race condition between process, it
     seems it due to the rpc server being run in a separate process. *)
    ~rpc_external:false
    ~kind
    {
      variant = None;
      tags = [Tag.flaky; "node"; "mode"; "batcher"];
      description = "multiple keys set for batcher";
    }
    ~uses:(fun _protocol -> [Constant.octez_smart_rollup_node])
  @@ fun _protocol sc_rollup tezos_node client ->
  (* nb_of_batcher * msg_per_batch * msg_size = expected_block_size
     16 * 32 * 1000 = 512_000 = maximum size of Tezos L1 block *)
  let nb_of_batcher = 16 in
  let msg_per_batch = 32 in
  let msg_size = 1000 in
  let* keys = gen_keys_then_transfer_tez client nb_of_batcher in
  let operators =
    List.map
      (fun k -> (Sc_rollup_node.Batching, k.Account.public_key_hash))
      keys
  in
  let* sc_rollup_node, _sc_rollup =
    setup_rollup
      ~parameters_ty:"string"
      ~kind
      ~mode:Batcher
      ~operators
      ~sc_rollup
      tezos_node
      client
  in
  let* () =
    Sc_rollup_node.run ~event_level:`Debug sc_rollup_node sc_rollup []
  in
  let batch () =
    let msg_cpt = ref 0 in
    (* create batch with different payloads so the logs show
       differents messages. *)
    List.init msg_per_batch (fun _ ->
        msg_cpt := !msg_cpt + 1 ;
        String.make msg_size @@ Char.chr (96 + !msg_cpt))
  in
  let inject_n_msgs_batches nb_of_batches =
    let* _hashes =
      Lwt.all @@ List.init nb_of_batches
      @@ fun _ ->
      Sc_rollup_node.RPC.call sc_rollup_node
      @@ Sc_rollup_rpc.post_local_batcher_injection ~messages:(batch ())
    in
    unit
  in
  let wait_for_included_check_batches_and_returns_pkhs () =
    let find_map_op_content op_content_json =
      let kind = JSON.(op_content_json |-> "kind" |> as_string) in
      if kind = "smart_rollup_add_messages" then (
        let nb_msgs =
          JSON.(op_content_json |-> "message" |> as_list |> List.length)
        in
        Check.(nb_msgs = msg_per_batch)
          Check.int
          ~error_msg:"%L found where %R was expected" ;
        let src = JSON.(op_content_json |-> "source" |> as_string) in
        Some src)
      else None
    in
    wait_for_included_and_map_ops_content
      sc_rollup_node
      tezos_node
      ~find_map_op_content
  in
  let check_against_operators_pkhs =
    let operators_pkhs = List.map snd operators |> List.sort String.compare in
    fun pkhs ->
      Check.((List.sort String.compare pkhs = operators_pkhs) (list string))
        ~error_msg:"%L found where %R was expected)"
  in
  Log.info "Injecting 2 * number of batchers into a full batch" ;
  let* () = inject_n_msgs_batches (2 * nb_of_batcher) in
  Log.info "Waiting until all batchers key have injected a batch" ;
  let* () =
    let* () = Client.bake_for_and_wait client
    and* () =
      wait_until_n_batches_are_injected sc_rollup_node ~nb_batches:nb_of_batcher
    in
    unit
  in
  Log.info "Baking to include all previous batches and the new injection salvo" ;
  let* _lvl = Client.bake_for_and_wait client
  and* pkhs_first_salvo = wait_for_included_check_batches_and_returns_pkhs ()
  and* () =
    wait_until_n_batches_are_injected sc_rollup_node ~nb_batches:nb_of_batcher
  in
  let () = check_against_operators_pkhs pkhs_first_salvo in
  let* _lvl = Client.bake_for_and_wait client
  and* pkhs_snd_salvo = wait_for_included_check_batches_and_returns_pkhs () in
  let () = check_against_operators_pkhs pkhs_snd_salvo in
  unit

(** Injector only uses key that have no operation in the mempool
   currently.
   1. Batcher setup:
   - 5 signers in the batcher.
   - 10 batches to inject.
   2. First Block:
   - Mempool:
     - Contains enough batches to fill the block from users with high fees.
     - Includes 5 batches injected by the batcher.
   - Block contents:
     - Only contains batches with high fees.
   3. Second Block:
   - Mempool:
     - Has 5 batches injected by the batcher.
   - Block contents:
     - Contains batches.
   - Processing:
     - Node re-injects 5 batches during block processing.
   4.Third Block:
   - Mempool:
     - Still has 5 batches injected by the batcher.
   - Block contents:
     - Contains batches.
*)
let test_injector_uses_available_keys ~kind =
  let operators =
    List.map
      (fun k -> (Sc_rollup_node.Batching, k.Account.public_key_hash))
      Constant.[bootstrap1; bootstrap2; bootstrap3; bootstrap4; bootstrap5]
  in
  let operators_pkh = List.map snd operators in
  let nb_operators = List.length operators in
  test_full_scenario
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/6650

     cf multiple_batcher_test comment. *)
    ~rpc_external:false
    ~kind
    ~operators
    ~mode:Batcher
    {
      variant = None;
      tags = ["injector"; "keys"];
      description = "injector uses only available signers";
    }
  @@ fun _protocol rollup_node rollup_addr node client ->
  Log.info "Batcher setup" ;
  let* () = Sc_rollup_node.run ~event_level:`Debug rollup_node rollup_addr [] in
  let batch ~msg_per_batch ~msg_size =
    let msg_cpt = ref 0 in
    (* create batch with different payloads so the logs show
       differents messages. *)
    List.init msg_per_batch (fun _ ->
        msg_cpt := !msg_cpt + 1 ;
        String.make msg_size @@ Char.chr (96 + !msg_cpt))
  in
  let batch_str ~msg_per_batch ~msg_size =
    let batch = batch ~msg_per_batch ~msg_size in
    let json = `A (List.map (fun s -> `String s) batch) in
    "text:" ^ Ezjsonm.to_string json
  in
  let reveal_key keys =
    Lwt_list.iter_p
      (fun key -> Runnable.run @@ Client.reveal ~src:key.Account.alias client)
      keys
  in
  let inject_with_keys keys ~msg_per_batch ~msg_size =
    Lwt_list.iter_p
      (fun key ->
        Client.Sc_rollup.send_message
          ~src:key.Account.alias
          ~fee:(Tez.of_int 10)
          ~fee_cap:(Tez.of_int 10)
          ~msg:(batch_str ~msg_per_batch ~msg_size)
          client)
      keys
  in
  let inject_n_msgs_batches_in_rollup_node ~nb_of_batches ~msg_per_batch
      ~msg_size =
    let* _hashes =
      Lwt.all @@ List.init nb_of_batches
      @@ fun _ ->
      Sc_rollup_node.RPC.call rollup_node
      @@ Sc_rollup_rpc.post_local_batcher_injection
           ~messages:(batch ~msg_per_batch ~msg_size)
    in
    unit
  in
  let find_map_op_content op_content_json =
    let kind = JSON.(op_content_json |-> "kind" |> as_string) in
    if kind = "smart_rollup_add_messages" then
      let src = JSON.(op_content_json |-> "source" |> as_string) in
      Some src
    else None
  in
  let wait_for_get_messages_and_get_batches_pkhs () =
    wait_for_get_messages_and_map_ops_content
      rollup_node
      node
      ~find_map_op_content
  in
  let wait_for_included_and_get_batches_pkhs () =
    wait_for_included_and_map_ops_content rollup_node node ~find_map_op_content
  in
  Log.info "Checking that the batcher keys received are correct." ;
  let check_keys ~received ~expected =
    let sorted_expected = List.sort String.compare expected in
    let sorted_received = List.sort String.compare received in
    Check.(
      (sorted_received = sorted_expected)
        (list string)
        ~error_msg:"%L found where %R was expected)")
  in
  (* nb_of_keys * msg_per_batch * msg_size = expected_block_size
     16 * 8 * 4000 = 512_000 = maximum size of Tezos L1 block *)
  let nb_of_keys = 16 and msg_per_batch = 8 and msg_size = 4000 in
  let* keys = gen_keys_then_transfer_tez client nb_of_keys in
  let keys_pkh = List.map (fun k -> k.Account.public_key_hash) keys in
  let* () = reveal_key keys in

  (* test start here *)
  let* _lvl = Client.bake_for_and_wait client in
  let* () =
    inject_n_msgs_batches_in_rollup_node
    (* we inject 2 times the number of operators so the rollup node
       must inject in two salvos all the batches. *)
      ~nb_of_batches:(2 * nb_operators)
      ~msg_per_batch
      ~msg_size
  in
  let* _lvl = Client.bake_for_and_wait client
  and* () =
    wait_until_n_batches_are_injected rollup_node ~nb_batches:nb_operators
  in
  Log.info "Inject enough batches to fill the block." ;
  let* () = inject_with_keys keys ~msg_per_batch ~msg_size in
  Log.info "First block's batches are the one injected directly to the L1." ;
  let* _lvl = Client.bake_for_and_wait client
  and* used_pkhs = wait_for_get_messages_and_get_batches_pkhs () in
  Log.info "Got pkhs." ;
  check_keys ~received:used_pkhs ~expected:keys_pkh ;
  Log.info
    "Second block's batches found are those injected by the rollup node \
     simultaneously with direct injection. Additionally, await the  injection \
     of N batches." ;
  let* _lvl = Client.bake_for_and_wait client
  and* () =
    wait_until_n_batches_are_injected rollup_node ~nb_batches:nb_operators
  and* used_pkhs = wait_for_included_and_get_batches_pkhs () in
  check_keys ~received:used_pkhs ~expected:operators_pkh ;
  Log.info
    "Last block's batches found are those injected by the rollup node using \
     keys that have been utilized in block up to this point." ;
  let* _lvl = Client.bake_for_and_wait client
  and* used_pkhs = wait_for_included_and_get_batches_pkhs () in
  check_keys ~received:used_pkhs ~expected:operators_pkh ;
  unit

let start_rollup_node_with_encrypted_key ~kind =
  test_l1_scenario
    ~hooks
    ~kind
    {
      variant = None;
      tags = ["rollup_node"];
      description = "start a rollup node with an encrypted key";
    }
    ~uses:(fun _protocol -> [Constant.octez_smart_rollup_node])
  @@ fun _protocol sc_rollup node client ->
  let encrypted_account =
    {
      alias = "encrypted_account";
      public_key_hash = "";
      public_key = "";
      Account.secret_key =
        Encrypted
          "edesk1n2uGpPtVaeyhWkZzTEcaPRzkQHrqkw5pk8VkZvp3rM5KSc3mYNH5cJEuNcfB91B3G3JakKzfLQSmrgF4ht";
    }
  in
  let password = "password" in
  let* () =
    let Account.{alias; secret_key; _} = encrypted_account in
    Client.import_encrypted_secret_key client ~alias secret_key ~password
  in
  let* () =
    Client.transfer
      ~burn_cap:Tez.(of_int 1)
      ~amount:(Tez.of_int 20_000)
      ~giver:Constant.bootstrap1.alias
      ~receiver:encrypted_account.alias
      client
  in
  let* _ = Client.bake_for_and_wait client in
  let rollup_node =
    Sc_rollup_node.create
      Operator
      node
      ~base_dir:(Client.base_dir client)
      ~default_operator:encrypted_account.alias
  in
  let* () = Sc_rollup_node.run ~wait_ready:false rollup_node sc_rollup [] in
  let* () =
    repeat 3 (fun () ->
        Sc_rollup_node.write_in_stdin rollup_node "invalid_password")
  and* () =
    Sc_rollup_node.check_error
      rollup_node
      ~exit_code:1
      ~msg:(rex "3 incorrect password attempts")
  in
  let password_file = Filename.temp_file "password_file" "" in
  let () = write_file password_file ~contents:password in
  let* () =
    Sc_rollup_node.run ~restart:true ~password_file rollup_node sc_rollup []
  in
  unit

let register_riscv ~protocols =
  test_rollup_node_boots_into_initial_state
    protocols
    ~supports:Protocol.(From_protocol 019)
    ~kind:"riscv" ;
  test_commitment_scenario
    ~supports:Protocol.(From_protocol 019)
    ~extra_tags:["modes"; "operator"]
    ~variant:"operator_publishes"
    (mode_publish Operator true)
    protocols
    ~kind:"riscv"

let register ~kind ~protocols =
  test_origination ~kind protocols ;
  test_rollup_get_genesis_info ~kind protocols ;
  test_rpcs ~kind protocols ;
  test_commitment_scenario
    ~variant:"commitment_is_stored"
    commitment_stored
    protocols
    ~kind ;
  test_commitment_scenario
    ~variant:"robust_to_failures"
    commitment_stored_robust_to_failures
    protocols
    ~kind ;
  test_commitment_scenario
    ~extra_tags:["modes"; "observer"]
    ~variant:"observer_does_not_publish"
    (mode_publish Observer false)
    protocols
    ~kind ;
  test_commitment_scenario
    ~extra_tags:["modes"; "maintenance"]
    ~variant:"maintenance_publishes"
    (mode_publish Maintenance true)
    protocols
    ~kind ;
  test_commitment_scenario
    ~extra_tags:["modes"; "batcher"]
    ~variant:"batcher_does_not_publish"
    (mode_publish Batcher false)
    protocols
    ~kind ;
  test_commitment_scenario
    ~extra_tags:["modes"; "operator"]
    ~variant:"operator_publishes"
    (mode_publish Operator true)
    protocols
    ~kind ;
  test_commitment_scenario
    ~commitment_period:15
    ~challenge_window:10080
    ~variant:"node_use_proto_param"
    commitment_stored
    protocols
    ~kind ;
  test_commitment_scenario
    ~variant:"non_final_level"
    commitment_not_published_if_non_final
    protocols
    ~kind ;
  test_commitment_scenario
    ~variant:"messages_reset"
    (commitments_messages_reset kind)
    protocols
    ~kind ;
  test_commitment_scenario
    ~variant:"handles_chain_reorgs"
    (commitments_reorgs ~kind ~switch_l1_node:false)
    protocols
    ~kind ;
  test_commitment_scenario
    ~variant:"handles_chain_reorgs_missing_blocks"
    (commitments_reorgs ~kind ~switch_l1_node:true)
    protocols
    ~kind ;
  test_commitment_scenario
    ~commitment_period:3
    ~variant:"correct_commitment_in_reproposal_reorg"
    ~extra_tags:["reproposal"]
    commitments_reproposal
    protocols
    ~kind ;
  test_commitment_scenario
    ~challenge_window:1
    ~variant:"no_commitment_publish_before_lcc"
    (* TODO: https://gitlab.com/tezos/tezos/-/issues/2976
       change tests so that we do not need to repeat custom parameters. *)
    commitment_before_lcc_not_published
    protocols
    ~kind ;
  test_commitment_scenario
    ~variant:"first_published_at_level_global"
    first_published_level_is_global
    protocols
    ~kind ;
  test_commitment_scenario
  (* Reduce commitment period here in order avoid waiting for default 30 (and even 60) blocks to be baked*)
    ~commitment_period:3
    ~variant:"consecutive commitments"
    test_consecutive_commitments
    protocols
    ~kind ;
  test_cement_ignore_commitment ~kind protocols ;
  test_outbox_message protocols ~kind

let register ~protocols =
  (* PVM-independent tests. We still need to specify a PVM kind
     because the tezt will need to originate a rollup. However,
     the tezt will not test for PVM kind specific features. *)
  test_rollup_list protocols ~kind:"wasm_2_0_0" ;
  test_valid_dispute_dissection ~kind:"arith" protocols ;
  test_refutation_reward_and_punishment protocols ~kind:"arith" ;
  test_timeout ~kind:"arith" protocols ;
  test_no_cementation_if_parent_not_lcc_or_if_disputed_commit
    ~kind:"arith"
    protocols ;
  test_refutation protocols ~kind:"arith" ;
  test_refutation protocols ~kind:"wasm_2_0_0" ;
  test_recover_bond_of_stakers protocols ;
  (* Specific Arith PVM tezts *)
  test_rollup_origination_boot_sector
    ~boot_sector:"10 10 10 + +"
    ~kind:"arith"
    protocols ;
  test_boot_sector_is_evaluated
    ~boot_sector1:"10 10 10 + +"
    ~boot_sector2:"31"
    ~kind:"arith"
    protocols ;
  test_reveals_4k protocols ;
  test_reveals_above_4k protocols ;
  test_reveals_fetch_remote protocols ;
  (* Specific Wasm PVM tezts *)
  test_rollup_node_run_with_kernel
    protocols
    ~kind:"wasm_2_0_0"
    ~kernel_name:"no_parse_random"
    ~internal:false ;
  test_rollup_node_run_with_kernel
    protocols
    ~kind:"wasm_2_0_0"
    ~kernel_name:"no_parse_bad_fingerprint"
    ~internal:false ;

  (* Specific riscv PVM tezt *)
  register_riscv ~protocols ;
  (* Shared tezts - will be executed for each PVMs. *)
  register ~kind:"wasm_2_0_0" ~protocols ;
  register ~kind:"arith" ~protocols ;
  (* Both Arith and Wasm PVM tezts *)
  test_bootstrap_smart_rollup_originated protocols ;
  test_bootstrap_private_smart_rollup_originated protocols ;
  (* Private rollup node *)
  test_private_rollup_whitelisted_staker protocols ;
  test_private_rollup_non_whitelisted_staker protocols ;
  test_rollup_whitelist_update ~kind:"wasm_2_0_0" protocols ;
  test_rollup_whitelist_outdated_update ~kind:"wasm_2_0_0" protocols

let register_protocol_independent () =
  let protocols = Protocol.[Alpha] in
  let with_kind kind =
    test_rollup_node_running ~kind protocols ;
    test_rollup_node_boots_into_initial_state protocols ~kind ;
    test_rollup_node_advances_pvm_state protocols ~kind ~internal:false ;
    test_rollup_node_advances_pvm_state protocols ~kind ~internal:true
  in
  with_kind "wasm_2_0_0" ;
  with_kind "arith" ;
  let kind = "wasm_2_0_0" in
  start_rollup_node_with_encrypted_key protocols ~kind ;
  test_rollup_node_missing_preimage_exit_at_initialisation protocols ;
  test_rollup_node_configuration protocols ~kind ;
  test_client_wallet protocols ~kind ;
  test_reveals_fails_on_wrong_hash protocols ;
  test_reveals_fails_on_unknown_hash protocols ;
  test_injector_auto_discard protocols ;
  test_accuser protocols ;
  test_bailout_refutation protocols ;
  test_multiple_batcher_key ~kind protocols ;
  test_injector_uses_available_keys protocols ~kind ;
  test_private_rollup_node_publish_in_whitelist protocols ;
  test_private_rollup_node_publish_not_in_whitelist protocols ;
  test_rollup_node_inbox
    ~kind
    ~variant:"stops"
    sc_rollup_node_stops_scenario
    protocols ;
  test_rollup_node_inbox
    ~kind
    ~variant:"disconnects"
    sc_rollup_node_disconnects_scenario
    protocols ;
  test_rollup_node_inbox
    ~kind
    ~variant:"handles_chain_reorg"
    sc_rollup_node_handles_chain_reorg
    protocols ;
  test_rollup_node_inbox
    ~kind
    ~variant:"batcher"
    ~extra_tags:["batcher"; Tag.flaky]
    sc_rollup_node_batcher
    protocols ;
  test_rollup_node_inbox ~kind ~variant:"basic" basic_scenario protocols ;
  test_gc
    "many_gc"
    ~kind
    ~challenge_window:5
    ~commitment_period:2
    ~history_mode:Full
    ~tags:[Tag.flaky]
    protocols ;
  test_gc
    "sparse_gc"
    ~kind
    ~challenge_window:10
    ~commitment_period:5
    ~history_mode:Full
    ~tags:[Tag.flaky]
    protocols ;
  test_gc
    "no_gc"
    ~kind
    ~challenge_window:10
    ~commitment_period:5
    ~history_mode:Archive
    protocols ;
  test_snapshots
    ~kind
    ~challenge_window:5
    ~commitment_period:2
    ~history_mode:Full
    protocols ;
  test_snapshots
    ~kind
    ~challenge_window:10
    ~commitment_period:5
    ~history_mode:Archive
    protocols ;
  custom_mode_empty_operation_kinds ~kind protocols ;
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/4373
     Uncomment this test as soon as the issue done.
     test_reinject_failed_commitment protocols ~kind ; *)
  test_late_rollup_node protocols ~kind ;
  test_late_rollup_node_2 protocols ~kind ;
  test_interrupt_rollup_node protocols ~kind ;
  test_arg_boot_sector_file ~kind protocols ;
  test_messages_processed_by_commitment ~kind protocols ;
  bailout_mode_not_publish ~kind protocols ;
  bailout_mode_fail_to_start_without_operator ~kind protocols ;
  bailout_mode_fail_operator_no_stake ~kind protocols ;
  bailout_mode_recover_bond_starting_no_commitment_staked ~kind protocols
