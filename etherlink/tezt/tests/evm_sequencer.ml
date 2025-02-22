(*****************************************************************************)
(*                                                                           *)
(* SPDX-License-Identifier: MIT                                              *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
(*                                                                           *)
(*****************************************************************************)

(* Testing
   -------
   Component:    Smart Optimistic Rollups: Etherlink Sequencer
   Requirement:  make -f kernels.mk build
                 npm install eth-cli
   Invocation:   dune exec etherlink/tezt/tests/main.exe -- --file evm_sequencer.ml
*)

open Sc_rollup_helpers
open Rpc.Syntax
open Contract_path

module Sequencer_rpc = struct
  let get_blueprint sequencer number =
    Runnable.run
    @@ Curl.get
         ~args:["--fail"]
         (Evm_node.endpoint sequencer
         ^ "/evm/blueprint/" ^ Int64.to_string number)

  let get_smart_rollup_address sequencer =
    let* res =
      Runnable.run
      @@ Curl.get
           ~args:["--fail"]
           (Evm_node.endpoint sequencer ^ "/evm/smart_rollup_address")
    in
    return (JSON.as_string res)
end

let uses _protocol =
  [
    Constant.octez_smart_rollup_node;
    Constant.octez_evm_node;
    Constant.smart_rollup_installer;
    Constant.WASM.evm_kernel;
  ]

open Helpers

type l1_contracts = {
  delayed_transaction_bridge : string;
  exchanger : string;
  bridge : string;
  admin : string;
  sequencer_admin : string;
}

type sequencer_setup = {
  node : Node.t;
  client : Client.t;
  sc_rollup_address : string;
  sc_rollup_node : Sc_rollup_node.t;
  sequencer : Evm_node.t;
  proxy : Evm_node.t;
  l1_contracts : l1_contracts;
}

let setup_l1_contracts ?(dictator = Constant.bootstrap1) client =
  (* Originates the delayed transaction bridge. *)
  let* delayed_transaction_bridge =
    Client.originate_contract
      ~alias:"evm-seq-delayed-bridge"
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.public_key_hash
      ~prg:(delayed_path ())
      ~burn_cap:Tez.one
      client
  in
  let* () = Client.bake_for_and_wait ~keys:[] client in
  (* Originates the exchanger. *)
  let* exchanger =
    Client.originate_contract
      ~alias:"exchanger"
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.public_key_hash
      ~init:"Unit"
      ~prg:(exchanger_path ())
      ~burn_cap:Tez.one
      client
  in
  let* () = Client.bake_for_and_wait ~keys:[] client in
  (* Originates the bridge. *)
  let* bridge =
    Client.originate_contract
      ~alias:"evm-bridge"
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.public_key_hash
      ~init:(sf "Pair %S None" exchanger)
      ~prg:(bridge_path ())
      ~burn_cap:Tez.one
      client
  in
  let* () = Client.bake_for_and_wait ~keys:[] client in
  (* Originates the administrator contract. *)
  let* admin =
    Client.originate_contract
      ~alias:"evm-admin"
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.public_key_hash
      ~init:(sf "%S" dictator.Account.public_key_hash)
      ~prg:(admin_path ())
      ~burn_cap:Tez.one
      client
  in
  let* () = Client.bake_for_and_wait ~keys:[] client in
  (* Originates the administrator contract. *)
  let* sequencer_admin =
    Client.originate_contract
      ~alias:"evm-sequencer-admin"
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.public_key_hash
      ~init:(sf "%S" dictator.Account.public_key_hash)
      ~prg:(admin_path ())
      ~burn_cap:Tez.one
      client
  in
  let* () = Client.bake_for_and_wait ~keys:[] client in
  return {delayed_transaction_bridge; exchanger; bridge; admin; sequencer_admin}

let setup_sequencer ?config ?genesis_timestamp ?time_between_blocks
    ?max_blueprints_lag ?max_blueprints_catchup ?catchup_cooldown
    ?delayed_inbox_timeout ?delayed_inbox_min_levels
    ?(bootstrap_accounts = Eth_account.bootstrap_accounts)
    ?(sequencer = Constant.bootstrap1) protocol =
  let* node, client = setup_l1 ?timestamp:genesis_timestamp protocol in
  let* l1_contracts = setup_l1_contracts client in
  let sc_rollup_node =
    Sc_rollup_node.create
      ~default_operator:Constant.bootstrap1.public_key_hash
      Batcher
      node
      ~base_dir:(Client.base_dir client)
  in
  let preimages_dir = Sc_rollup_node.data_dir sc_rollup_node // "wasm_2_0_0" in
  let base_config =
    Configuration.make_config
      ~bootstrap_accounts
      ~sequencer:sequencer.public_key
      ~delayed_bridge:l1_contracts.delayed_transaction_bridge
      ~ticketer:l1_contracts.exchanger
      ~administrator:l1_contracts.admin
      ~sequencer_administrator:l1_contracts.sequencer_admin
      ?delayed_inbox_timeout
      ?delayed_inbox_min_levels
      ()
  in
  let config =
    match (config, base_config) with
    | Some (`Config config), Some (`Config base) ->
        Some (`Config (base @ config))
    | Some (`Path path), Some (`Config base) -> Some (`Both (base, path))
    | None, _ -> base_config
    | Some (`Config config), None -> Some (`Config config)
    | Some (`Path path), None -> Some (`Path path)
  in
  let* {output; _} =
    prepare_installer_kernel ~preimages_dir ?config Constant.WASM.evm_kernel
  in
  let* sc_rollup_address =
    originate_sc_rollup
      ~kind:"wasm_2_0_0"
      ~boot_sector:("file:" ^ output)
      ~parameters_ty:Helpers.evm_type
      client
  in
  let* () =
    Sc_rollup_node.run sc_rollup_node sc_rollup_address [Log_kernel_debug]
  in
  let private_rpc_port = Port.fresh () in
  let mode =
    let sequencer =
      match sequencer.secret_key with
      | Unencrypted sk -> sk
      | Encrypted _ -> Test.fail "Provide an unencrypted key for the sequencer"
    in
    Evm_node.Sequencer
      {
        initial_kernel = output;
        preimage_dir = preimages_dir;
        private_rpc_port;
        time_between_blocks;
        sequencer;
        genesis_timestamp;
        max_blueprints_lag;
        max_blueprints_catchup;
        catchup_cooldown;
        devmode = true;
      }
  in
  let* sequencer =
    Evm_node.init ~mode (Sc_rollup_node.endpoint sc_rollup_node)
  in
  let* proxy =
    Evm_node.init
      ~mode:(Proxy {devmode = true})
      (Sc_rollup_node.endpoint sc_rollup_node)
  in
  return
    {
      node;
      client;
      sequencer;
      proxy;
      l1_contracts;
      sc_rollup_address;
      sc_rollup_node;
    }

let send_raw_transaction_to_delayed_inbox ?(amount = Tez.one) ?expect_failure
    ~sc_rollup_node ~node ~client ~l1_contracts ~sc_rollup_address raw_tx =
  let expected_hash =
    `Hex raw_tx |> Hex.to_bytes |> Tezos_crypto.Hacl.Hash.Keccak_256.digest
    |> Hex.of_bytes |> Hex.show
  in
  let* () =
    Client.transfer
      ~arg:(sf "Pair %S 0x%s" sc_rollup_address raw_tx)
      ~amount
      ~giver:Constant.bootstrap2.public_key_hash
      ~receiver:l1_contracts.delayed_transaction_bridge
      ~burn_cap:Tez.one
      ?expect_failure
      client
  in
  let* () = Client.bake_for_and_wait ~keys:[] client in
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  Lwt.return expected_hash

let send_deposit_to_delayed_inbox ~amount ~l1_contracts ~depositor ~receiver
    ~sc_rollup_node ~sc_rollup_address ~node client =
  let* () =
    Client.transfer
      ~entrypoint:"deposit"
      ~arg:(sf "Pair %S %s" sc_rollup_address receiver)
      ~amount
      ~giver:depositor.Account.public_key_hash
      ~receiver:l1_contracts.bridge
      ~burn_cap:Tez.one
      client
  in
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  unit

let test_remove_sequencer =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "admin"]
    ~title:"Remove sequencer via sequencer admin contract"
    ~uses
  @@ fun protocol ->
  let* {
         sequencer;
         proxy;
         sc_rollup_node;
         node;
         client;
         sc_rollup_address;
         l1_contracts;
         _;
       } =
    setup_sequencer ~time_between_blocks:Nothing protocol
  in
  (* Produce blocks to show that both the sequencer and proxy are not
     progressing. *)
  let* _ =
    repeat 5 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  (* Both are at genesis *)
  let*@ sequencer_head = Rpc.block_number sequencer in
  let*@ proxy_head = Rpc.block_number proxy in
  Check.((sequencer_head = 0l) int32)
    ~error_msg:"Sequencer should be at genesis" ;
  Check.((sequencer_head = proxy_head) int32)
    ~error_msg:"Sequencer and proxy should have the same block number" ;
  (* Remove the sequencer via the sequencer-admin contract. *)
  let* () =
    Client.transfer
      ~amount:Tez.zero
      ~giver:Constant.bootstrap1.public_key_hash
      ~receiver:l1_contracts.sequencer_admin
      ~arg:(sf "Pair %S 0x" sc_rollup_address)
      ~burn_cap:Tez.one
      client
  in
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  (* Produce L1 blocks to show that only the proxy is progressing *)
  let* _ =
    repeat 5 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  (* Sequencer is at genesis, proxy is at [advance]. *)
  let*@ sequencer_head = Rpc.block_number sequencer in
  let*@ proxy_head = Rpc.block_number proxy in
  Check.((sequencer_head = 0l) int32)
    ~error_msg:"Sequencer should still be at genesis" ;
  Check.((proxy_head > 0l) int32) ~error_msg:"Proxy should have advanced" ;

  unit

let test_persistent_state =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"]
    ~title:"Sequencer state is persistent across runs"
    ~uses
  @@ fun protocol ->
  let* {sequencer; _} = setup_sequencer protocol in
  (* Force the sequencer to produce a block. *)
  let* _ = Rpc.produce_block sequencer in
  (* Ask for the current block. *)
  let*@ block_number = Rpc.block_number sequencer in
  Check.is_true
    ~__LOC__
    (block_number > 0l)
    ~error_msg:"The sequencer should have produced a block" ;
  (* Terminate the sequencer. *)
  let* () = Evm_node.terminate sequencer in
  (* Restart it. *)
  let* () = Evm_node.run sequencer in
  (* Assert the block number is at least [block_number]. Asserting
     that the block number is exactly the same as {!block_number} can
     be flaky if a block is produced between the restart and the
     RPC. *)
  let*@ new_block_number = Rpc.block_number sequencer in
  Check.is_true
    ~__LOC__
    (new_block_number >= block_number)
    ~error_msg:"The sequencer should have produced a block" ;
  unit

let test_publish_blueprints =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "data"]
    ~title:"Sequencer publishes the blueprints to L1"
    ~uses
  @@ fun protocol ->
  let* {sequencer; proxy; node; client; sc_rollup_node; _} =
    setup_sequencer ~time_between_blocks:Nothing protocol
  in
  let* _ =
    repeat 5 (fun () ->
        let* _ = Rpc.produce_block sequencer in
        unit)
  in

  let* () = Evm_node.wait_for_blueprint_injected ~timeout:5. sequencer 5 in

  (* Ask for the current block. *)
  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in

  (* At this point, the evm node should called the batcher endpoint to publish
     all the blueprints. Stopping the node is then not a problem. *)
  let* () =
    repeat 10 (fun () ->
        let* _ = next_rollup_node_level ~node ~client ~sc_rollup_node in
        unit)
  in

  (* We have unfortunately noticed that the test can be flaky. Sometimes,
     the following RPC is done before the proxy being initialised, even though
     we wait for it. The source of flakiness is unknown but happens very rarely,
     we put a small sleep to make the least flaky possible. *)
  let* () = Lwt_unix.sleep 2. in
  let*@ rollup_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash = rollup_head.hash) (option string))
    ~error_msg:"Expected the same head on the rollup node and the sequencer" ;
  unit

let test_resilient_to_rollup_node_disconnect =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "data"]
    ~title:"Sequencer is resilient to rollup node disconnection"
    ~uses
  @@ fun protocol ->
  (* The objective of this test is to show that the sequencer can deal with
     rollup node outage. The logic of the sequencer at the moment is to
     wait for its advance on the rollup node to be more than [max_blueprints_lag]
     before sending at most [max_blueprints_catchup] blueprints. The sequencer
     waits for [catchup_cooldown] L1 blocks before checking if it needs to push
     new blueprints again. This scenario checks this logic. *)
  let max_blueprints_lag = 10 in
  let max_blueprints_catchup = max_blueprints_lag - 3 in
  let catchup_cooldown = 10 in
  let first_batch_blueprints_count = 5 in
  let ensure_rollup_node_publish = 5 in

  let* {sequencer; proxy; sc_rollup_node; sc_rollup_address; node; client; _} =
    setup_sequencer
      ~max_blueprints_lag
      ~max_blueprints_catchup
      ~catchup_cooldown
      ~time_between_blocks:Nothing
      protocol
  in

  (* Produce blueprints *)
  let* _ =
    repeat first_batch_blueprints_count (fun () ->
        let* _ = Rpc.produce_block sequencer in
        unit)
  in
  let* () =
    Evm_node.wait_for_blueprint_injected
      ~timeout:(float_of_int first_batch_blueprints_count)
      sequencer
      first_batch_blueprints_count
  in

  (* Produce some L1 blocks so that the rollup node publishes the blueprints. *)
  let* _ =
    repeat ensure_rollup_node_publish (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in

  (* Check sequencer and rollup consistency *)
  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash = rollup_node_head.hash) (option string))
    ~error_msg:"The head should be the same before the outage" ;

  (* Kill the rollup node *)
  let* () = Sc_rollup_node.kill sc_rollup_node in

  (* The sequencer node should keep producing blocks, enough so that
     it cannot catchup in one go. *)
  let* _ =
    repeat (2 * max_blueprints_lag) (fun () ->
        let* _ = Rpc.produce_block sequencer in
        unit)
  in

  let* () =
    Evm_node.wait_for_blueprint_applied
      sequencer
      ~timeout:5.
      (first_batch_blueprints_count + (2 * max_blueprints_lag))
  in

  (* Kill the sequencer node, restart the rollup node, restart the sequencer to
     reestablish the connection *)
  let* () = Sc_rollup_node.run sc_rollup_node sc_rollup_address [] in
  let* () = Sc_rollup_node.wait_for_ready sc_rollup_node in

  let* () = Evm_node.terminate sequencer in
  let* () = Evm_node.run sequencer in
  let* () = Evm_node.wait_for_ready sequencer in

  (* Produce enough blocks in advance to ensure the sequencer node will catch
     up at the end. *)
  let* _ =
    repeat max_blueprints_lag (fun () ->
        let* _ = Rpc.produce_block sequencer in
        unit)
  in

  let* () =
    Evm_node.wait_for_blueprint_applied
      sequencer
      ~timeout:5.
      (first_batch_blueprints_count + (2 * max_blueprints_catchup) + 1)
  in

  (* Give some time for the sequencer node to inject the first round of
     blueprints *)
  let* _ =
    repeat ensure_rollup_node_publish (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in

  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.(
    (rollup_node_head.number
    = Int32.(of_int (first_batch_blueprints_count + max_blueprints_catchup)))
      int32)
    ~error_msg:
      "The rollup node should have received the first round of lost blueprints" ;

  (* Go through several cooldown periods to let the sequencer sends the rest of
     the blueprints. *)
  let* _ =
    repeat (2 * catchup_cooldown) (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in

  (* Check the consistency again *)
  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash = rollup_node_head.hash) (option string))
    ~error_msg:"The head should be the same after the outage" ;

  unit

let test_can_fetch_blueprint =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "data"]
    ~title:"Sequencer can provide blueprints on demand"
    ~uses
  @@ fun protocol ->
  let* {sequencer; _} = setup_sequencer ~time_between_blocks:Nothing protocol in
  let number_of_blocks = 5 in
  let* _ =
    repeat number_of_blocks (fun () ->
        let* _ = Rpc.produce_block sequencer in
        unit)
  in

  let* () = Evm_node.wait_for_blueprint_injected ~timeout:5. sequencer 5 in

  let* blueprints =
    fold number_of_blocks [] (fun i acc ->
        let* blueprint =
          Sequencer_rpc.get_blueprint sequencer Int64.(of_int @@ (i + 1))
        in
        return (blueprint :: acc))
  in

  (* Test for uniqueness  *)
  let blueprints_uniq =
    List.sort_uniq
      (fun b1 b2 -> String.compare (JSON.encode b1) (JSON.encode b2))
      blueprints
  in
  if List.length blueprints = List.length blueprints_uniq then unit
  else
    Test.fail
      ~__LOC__
      "At least two blueprints from a different level are equal."

let test_can_fetch_smart_rollup_address =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "rpc"]
    ~title:"Sequencer can return the smart rollup address on demand"
    ~uses
  @@ fun protocol ->
  let* {sequencer; sc_rollup_address; _} =
    setup_sequencer ~time_between_blocks:Nothing protocol
  in
  let* claimed_address = Sequencer_rpc.get_smart_rollup_address sequencer in

  Check.((sc_rollup_address = claimed_address) string)
    ~error_msg:"Returned address is not the expected one" ;

  unit

let test_send_transaction_to_delayed_inbox =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"]
    ~title:"Send a transaction to the delayed inbox"
    ~uses
  @@ fun protocol ->
  (* Start the evm node *)
  let* {client; node; l1_contracts; sc_rollup_address; sc_rollup_node; _} =
    setup_sequencer protocol
  in
  let raw_transfer =
    "f86d80843b9aca00825b0494b53dc01974176e5dff2298c5a94343c2585e3c54880de0b6b3a764000080820a96a07a3109107c6bd1d555ce70d6253056bc18996d4aff4d4ea43ff175353f49b2e3a05f9ec9764dc4a3c3ab444debe2c3384070de9014d44732162bb33ee04da187ef"
  in
  let send ~amount ?expect_failure () =
    send_raw_transaction_to_delayed_inbox
      ~sc_rollup_node
      ~client
      ~l1_contracts
      ~sc_rollup_address
      ~node
      ~amount
      ?expect_failure
      raw_transfer
  in
  (* Test that paying less than 1XTZ is not allowed. *)
  let* _hash =
    send ~amount:(Tez.parse_floating "0.9") ~expect_failure:true ()
  in
  (* Test the correct case where the user burns 1XTZ to send the transaction. *)
  let* hash = send ~amount:Tez.one ~expect_failure:false () in
  (* Assert that the expected transaction hash is found in the delayed inbox
     durable storage path. *)
  let* delayed_transactions_hashes =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_durable_state_value
         ~pvm_kind:"wasm_2_0_0"
         ~operation:Sc_rollup_rpc.Subkeys
         ~key:"/evm/delayed-inbox"
         ()
  in
  Check.(list_mem string hash delayed_transactions_hashes)
    ~error_msg:"hash %L should be present in the delayed inbox %R" ;
  (* Test that paying more than 1XTZ is allowed. *)
  let* _hash =
    send ~amount:(Tez.parse_floating "1.1") ~expect_failure:false ()
  in
  unit

let test_send_deposit_to_delayed_inbox =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"; "deposit"]
    ~title:"Send a deposit to the delayed inbox"
    ~uses
  @@ fun protocol ->
  let* {client; node; l1_contracts; sc_rollup_address; sc_rollup_node; _} =
    setup_sequencer protocol
  in
  let amount = Tez.of_int 16 in
  let depositor = Constant.bootstrap5 in
  let receiver =
    Eth_account.
      {
        address = "0x1074Fd1EC02cbeaa5A90450505cF3B48D834f3EB";
        private_key =
          "0xb7c548b5442f5b28236f0dcd619f65aaaafd952240908adcf9642d8e616587ee";
        public_key =
          "0466ed90f9a86c0908746475fbe0a40c72237de22d89076302e22c2a8da259b4aba5c7ee1f3dc3fd0b240645462620ae62b6fe8fe5b3464c3b1b4ae6c06c97b7b6";
      }
  in
  let* () =
    send_deposit_to_delayed_inbox
      ~amount
      ~l1_contracts
      ~depositor
      ~receiver:receiver.address
      ~sc_rollup_node
      ~sc_rollup_address
      ~node
      client
  in
  let* delayed_transactions_hashes =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_durable_state_value
         ~pvm_kind:"wasm_2_0_0"
         ~operation:Sc_rollup_rpc.Subkeys
         ~key:"/evm/delayed-inbox"
         ()
  in
  Check.(
    list_mem
      string
      "a07feb67aff94089c8d944f5f8ffb5acc37306da9102fc310264e90999a42eb1"
      delayed_transactions_hashes)
    ~error_msg:"the deposit is not present in the delayed inbox" ;
  unit

let test_rpc_produceBlock =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "produce_block"]
    ~title:"RPC method produceBlock"
    ~uses
  @@ fun protocol ->
  (* Set a large [time_between_blocks] to make sure the block production is
     triggered by the RPC call. *)
  let* {sequencer; _} = setup_sequencer ~time_between_blocks:Nothing protocol in
  let*@ start_block_number = Rpc.block_number sequencer in
  let* _ = Rpc.produce_block sequencer in
  let*@ new_block_number = Rpc.block_number sequencer in
  Check.((Int32.succ start_block_number = new_block_number) int32)
    ~error_msg:"Expected new block number to be %L, but got: %R" ;
  unit

let wait_for_event ?(levels = 10) event_watcher ~sequencer ~sc_rollup_node ~node
    ~client ~error_msg =
  let event_value = ref None in
  let _ =
    let* return_value = event_watcher in
    event_value := Some return_value ;
    unit
  in
  let rec rollup_node_loop n =
    if n = 0 then Test.fail error_msg
    else
      let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
      let* _ = Rpc.produce_block sequencer in
      match !event_value with
      | Some value -> return value
      | None -> rollup_node_loop (n - 1)
  in
  Lwt.pick [rollup_node_loop levels]

let wait_for_delayed_inbox_add_tx_and_injected ~sequencer ~sc_rollup_node ~node
    ~client =
  let event_watcher =
    let added =
      Evm_node.wait_for sequencer "delayed_inbox_add_transaction.v0"
      @@ fun json ->
      let hash = JSON.(json |-> "hash" |> as_string) in
      Some hash
    in
    let injected =
      Evm_node.wait_for sequencer "tx_pool_transaction_injected.v0"
      @@ fun json ->
      let hash = JSON.(json |> as_string) in
      Some hash
    in
    let* added_hash, injected_hash = Lwt.both added injected in
    Check.((added_hash = injected_hash) string)
      ~error_msg:"Injected hash %R is not the expected one %L" ;
    Lwt.return_unit
  in
  wait_for_event
    event_watcher
    ~sequencer
    ~sc_rollup_node
    ~node
    ~client
    ~error_msg:
      "Timed out while waiting for transaction to be added to the delayed \
       inbox and injected"

let wait_for_delayed_inbox_fetch ~sequencer ~sc_rollup_node ~node ~client =
  let event_watcher =
    Evm_node.wait_for sequencer "delayed_inbox_fetch_succeeded.v0"
    @@ fun json ->
    let nb = JSON.(json |-> "nb" |> as_int) in
    Some nb
  in
  wait_for_event
    event_watcher
    ~sequencer
    ~sc_rollup_node
    ~node
    ~client
    ~error_msg:"Timed out while waiting for delayed inbox to be fetched"

let wait_until_delayed_inbox_is_empty ~sequencer ~sc_rollup_node ~node ~client =
  let levels = 10 in
  let rec go n =
    if n = 0 then
      Test.fail "Timed out waiting for the delayed inbox to be empty"
    else
      let* nb =
        wait_for_delayed_inbox_fetch ~sequencer ~sc_rollup_node ~node ~client
      in
      if nb = 0 then Lwt.return_unit else go (n - 1)
  in
  go levels

let test_delayed_transfer_is_included =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"; "inclusion"]
    ~title:"Delayed transaction is included"
    ~uses
  @@ fun protocol ->
  (* Start the evm node *)
  let* {
         client;
         node;
         l1_contracts;
         sc_rollup_address;
         sc_rollup_node;
         sequencer;
         _;
       } =
    setup_sequencer protocol
  in
  let endpoint = Evm_node.endpoint sequencer in
  (* This is a transfer from Eth_account.bootstrap_accounts.(0) to
     Eth_account.bootstrap_accounts.(1). *)
  let raw_transfer =
    "f86d80843b9aca00825b0494b53dc01974176e5dff2298c5a94343c2585e3c54880de0b6b3a764000080820a96a07a3109107c6bd1d555ce70d6253056bc18996d4aff4d4ea43ff175353f49b2e3a05f9ec9764dc4a3c3ab444debe2c3384070de9014d44732162bb33ee04da187ef"
  in
  let sender = Eth_account.bootstrap_accounts.(0).address in
  let receiver = Eth_account.bootstrap_accounts.(1).address in
  let* sender_balance_prev = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_prev = Eth_cli.balance ~account:receiver ~endpoint in
  let* _hash =
    send_raw_transaction_to_delayed_inbox
      ~sc_rollup_node
      ~client
      ~l1_contracts
      ~sc_rollup_address
      ~node
      raw_transfer
  in
  let* () =
    wait_for_delayed_inbox_add_tx_and_injected
      ~sequencer
      ~sc_rollup_node
      ~node
      ~client
  in
  let* () =
    wait_until_delayed_inbox_is_empty ~sequencer ~sc_rollup_node ~node ~client
  in
  let* sender_balance_next = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_next = Eth_cli.balance ~account:receiver ~endpoint in
  Check.((sender_balance_prev <> sender_balance_next) Wei.typ)
    ~error_msg:"Balance should be updated" ;
  Check.((receiver_balance_prev <> receiver_balance_next) Wei.typ)
    ~error_msg:"Balance should be updated" ;
  Check.((sender_balance_prev > sender_balance_next) Wei.typ)
    ~error_msg:"Expected a smaller balance" ;
  Check.((receiver_balance_next > receiver_balance_prev) Wei.typ)
    ~error_msg:"Expected a bigger balance" ;
  unit

let test_delayed_deposit_is_included =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"; "inclusion"; "deposit"]
    ~title:"Delayed deposit is included"
    ~uses
  @@ fun protocol ->
  (* Start the evm node *)
  let* {
         client;
         node;
         l1_contracts;
         sc_rollup_address;
         sc_rollup_node;
         sequencer;
         _;
       } =
    setup_sequencer protocol
  in
  let endpoint = Evm_node.endpoint sequencer in

  let amount = Tez.of_int 16 in
  let depositor = Constant.bootstrap5 in
  let receiver =
    Eth_account.
      {
        address = "0x1074Fd1EC02cbeaa5A90450505cF3B48D834f3EB";
        private_key =
          "0xb7c548b5442f5b28236f0dcd619f65aaaafd952240908adcf9642d8e616587ee";
        public_key =
          "0466ed90f9a86c0908746475fbe0a40c72237de22d89076302e22c2a8da259b4aba5c7ee1f3dc3fd0b240645462620ae62b6fe8fe5b3464c3b1b4ae6c06c97b7b6";
      }
  in
  let* receiver_balance_prev =
    Eth_cli.balance ~account:receiver.address ~endpoint
  in
  let* () =
    send_deposit_to_delayed_inbox
      ~amount
      ~l1_contracts
      ~depositor
      ~receiver:receiver.address
      ~sc_rollup_node
      ~sc_rollup_address
      ~node
      client
  in
  let* () =
    wait_for_delayed_inbox_add_tx_and_injected
      ~sequencer
      ~sc_rollup_node
      ~node
      ~client
  in
  let* () =
    wait_until_delayed_inbox_is_empty ~sequencer ~sc_rollup_node ~node ~client
  in
  let* receiver_balance_next =
    Eth_cli.balance ~account:receiver.address ~endpoint
  in
  Check.((receiver_balance_next > receiver_balance_prev) Wei.typ)
    ~error_msg:"Expected a bigger balance" ;
  unit

(** test to initialise a sequencer data dir based on a rollup node
        data dir *)
let test_init_from_rollup_node_data_dir =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "rollup_node"; "init"]
    ~uses:(fun _protocol ->
      [
        Constant.octez_smart_rollup_node;
        Constant.octez_evm_node;
        Constant.smart_rollup_installer;
        Constant.WASM.evm_kernel;
      ])
    ~title:"Init evm node sequencer data dir from a rollup node data dir"
  @@ fun protocol ->
  let* {sc_rollup_node; sequencer; proxy; client; _} =
    setup_sequencer ~time_between_blocks:Nothing protocol
  in
  (* a sequencer is needed to produce an initial block *)
  let* () =
    repeat 5 (fun () ->
        let* _l2_lvl = Rpc.produce_block sequencer in
        let* _lvl = Client.bake_for_and_wait client in
        let* _lvl = Sc_rollup_node.wait_sync ~timeout:30. sc_rollup_node in
        unit)
  in
  let* () = Evm_node.terminate sequencer in
  let evm_node' =
    Evm_node.create
      ~mode:(Evm_node.mode sequencer)
      (Sc_rollup_node.endpoint sc_rollup_node)
  in
  let* () = Evm_node.init_from_rollup_node_data_dir evm_node' sc_rollup_node in
  let* () = Evm_node.run evm_node' in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" evm_node' in
  Check.((sequencer_head.number = rollup_node_head.number) int32)
    ~error_msg:"block number is not equal (sequencer: %L; rollup: %R)" ;
  let* _l2_lvl = Rpc.produce_block sequencer in
  let* _lvl = Client.bake_for_and_wait client in
  let* _lvl = Sc_rollup_node.wait_sync ~timeout:30. sc_rollup_node in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" evm_node' in
  Check.((sequencer_head.number = rollup_node_head.number) int32)
    ~error_msg:"block number is not equal (sequencer: %L; rollup: %R)" ;
  unit

let test_observer_applies_blueprint =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "observer"]
    ~title:"Can start an Observer node"
    ~uses
  @@ fun protocol ->
  (* Start the evm node *)
  let tbb = 1. in
  let* {sequencer = sequencer_node; sc_rollup_node; _} =
    setup_sequencer ~time_between_blocks:(Time_between_blocks tbb) protocol
  in
  let preimage_dir = Sc_rollup_node.data_dir sc_rollup_node // "wasm_2_0_0" in
  let observer_node =
    Evm_node.create
      ~mode:
        (Observer
           {
             initial_kernel = Evm_node.initial_kernel sequencer_node;
             preimage_dir;
           })
      (Evm_node.endpoint sequencer_node)
  in
  let* () = Evm_node.run observer_node in
  let* () = Evm_node.wait_for_ready observer_node in
  let levels_to_wait = 3 in
  let timeout = tbb *. float_of_int levels_to_wait *. 2. in

  let* _ =
    Lwt.both
      (Evm_node.wait_for_blueprint_applied
         ~timeout
         observer_node
         levels_to_wait)
      (Evm_node.wait_for_blueprint_applied
         ~timeout
         sequencer_node
         levels_to_wait)
  in

  let*@ sequencer_head =
    Rpc.get_block_by_number ~block:"latest" sequencer_node
  in
  let*@ observer_head = Rpc.get_block_by_number ~block:"latest" observer_node in

  Check.((sequencer_head.hash = observer_head.hash) (option string))
    ~error_msg:"head hash is not equal (sequencer: %L; rollup: %R)" ;

  unit

(** This tests the situation where the kernel has an upgrade but the sequencer
    does not upgrade as well, resulting in a different state in the sequencer
    and rollup-node. *)
let test_upgrade_kernel_unsync =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "upgrade"; "unsync"]
    ~title:"Unsynchronised upgrade with rollup-node leads to a fork"
    ~uses:(fun protocol -> Constant.WASM.debug_kernel :: uses protocol)
  @@ fun protocol ->
  (* Add a delay between first block and activation timestamp. *)
  let genesis_timestamp =
    Client.(At (Time.of_notation_exn "2020-01-01T00:00:00Z"))
  in
  let activation_timestamp = "2020-01-01T00:00:10Z" in

  let* {
         sc_rollup_node;
         l1_contracts;
         sc_rollup_address;
         client;
         sequencer;
         proxy;
         node;
         _;
       } =
    setup_sequencer ~genesis_timestamp ~time_between_blocks:Nothing protocol
  in
  (* Sends the upgrade to L1, but not to the sequencer. *)
  let* () =
    upgrade
      ~sc_rollup_node
      ~sc_rollup_address
      ~admin:Constant.bootstrap1.public_key_hash
      ~admin_contract:l1_contracts.admin
      ~client
      ~upgrade_to:Constant.WASM.debug_kernel
      ~activation_timestamp
      ~evm_node:None
  in

  (* Per the activation timestamp, the state will remain synchronised until
     the kernel is upgraded. *)
  let* _ =
    repeat 2 (fun () ->
        let* _ =
          Rpc.produce_block ~timestamp:"2020-01-01T00:00:05Z" sequencer
        in
        unit)
  in
  let* () =
    repeat 4 (fun () ->
        let* _ = next_rollup_node_level ~node ~client ~sc_rollup_node in
        unit)
  in

  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash = rollup_node_head.hash) (option string))
    ~error_msg:"The head should be the same before the upgrade" ;

  (* Produce a block after activation timestamp, the rollup node will upgrade
     to debug kernel and therefore not produce the block. *)
  let* _ =
    repeat 2 (fun () ->
        let* _ =
          Rpc.produce_block ~timestamp:"2020-01-01T00:00:15Z" sequencer
        in
        unit)
  in
  let* () =
    repeat 4 (fun () ->
        let* _ = next_rollup_node_level ~node ~client ~sc_rollup_node in
        unit)
  in

  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash <> rollup_node_head.hash) (option string))
    ~error_msg:"The head shouldn't be the same after upgrade" ;
  Check.((sequencer_head.number > rollup_node_head.number) int32)
    ~error_msg:"The rollup node should be behind the sequencer" ;

  unit

(** This tests the situation where the kernel has an upgrade and the
    sequencer is notified via the private RPC. This is the opposite
    test of {!test_upgrade_kernel_unsync}. *)
let test_upgrade_kernel_sync =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "upgrade"; "sync"]
    ~title:"Synchronize upgrade with rollup-node"
    ~uses:(fun protocol -> Constant.WASM.debug_kernel :: uses protocol)
  @@ fun protocol ->
  (* Add a delay between first block and activation timestamp. *)
  let genesis_timestamp =
    Client.(At (Time.of_notation_exn "2020-01-01T00:00:00Z"))
  in
  let activation_timestamp = "2020-01-01T00:00:10Z" in

  let* {
         sc_rollup_node;
         l1_contracts;
         sc_rollup_address;
         client;
         sequencer;
         proxy;
         node;
         _;
       } =
    setup_sequencer ~genesis_timestamp ~time_between_blocks:Nothing protocol
  in
  (* Sends the upgrade to L1 and sequencer. *)
  let* () =
    upgrade
      ~sc_rollup_node
      ~sc_rollup_address
      ~admin:Constant.bootstrap1.public_key_hash
      ~admin_contract:l1_contracts.admin
      ~client
      ~upgrade_to:Constant.WASM.debug_kernel
      ~activation_timestamp
      ~evm_node:(Some sequencer)
  in

  (* Per the activation timestamp, the state will remain synchronised until
     the kernel is upgraded. *)
  let* _ =
    repeat 2 (fun () ->
        let* _ =
          Rpc.produce_block ~timestamp:"2020-01-01T00:00:05Z" sequencer
        in
        unit)
  in
  let* () =
    repeat 4 (fun () ->
        let* _ = next_rollup_node_level ~node ~client ~sc_rollup_node in
        unit)
  in
  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash = rollup_node_head.hash) (option string))
    ~error_msg:"The head should be the same before the upgrade" ;

  (* Produce a block after activation timestamp, the rollup node and
     the sequencer will both upgrade to debug kernel and therefore not
     produce the block. *)
  let* _ =
    repeat 2 (fun () ->
        let* _ =
          Rpc.produce_block ~timestamp:"2020-01-01T00:00:15Z" sequencer
        in
        unit)
  in
  let* () =
    repeat 4 (fun () ->
        let* _ = next_rollup_node_level ~node ~client ~sc_rollup_node in
        unit)
  in

  let*@ sequencer_head = Rpc.get_block_by_number ~block:"latest" sequencer in
  let*@ rollup_node_head = Rpc.get_block_by_number ~block:"latest" proxy in
  Check.((sequencer_head.hash = rollup_node_head.hash) (option string))
    ~error_msg:"The head shouldn't be the same after upgrade" ;
  unit

let test_delayed_transfer_timeout =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"; "timeout"]
    ~title:"Delayed transaction timeout"
    ~uses
  @@ fun protocol ->
  (* Start the evm node *)
  let* {
         client;
         node;
         l1_contracts;
         sc_rollup_address;
         sc_rollup_node;
         sequencer;
         proxy;
       } =
    setup_sequencer
      ~delayed_inbox_timeout:3
      ~delayed_inbox_min_levels:1
      protocol
  in
  (* Kill the sequencer *)
  let* () = Evm_node.terminate sequencer in
  let endpoint = Evm_node.endpoint proxy in
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  let sender = Eth_account.bootstrap_accounts.(0).address in
  let _ = Rpc.block_number proxy in
  let receiver = Eth_account.bootstrap_accounts.(1).address in
  let* sender_balance_prev = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_prev = Eth_cli.balance ~account:receiver ~endpoint in
  (* This is a transfer from Eth_account.bootstrap_accounts.(0) to
     Eth_account.bootstrap_accounts.(1). *)
  let raw_transfer =
    "f86d80843b9aca00825b0494b53dc01974176e5dff2298c5a94343c2585e3c54880de0b6b3a764000080820a96a07a3109107c6bd1d555ce70d6253056bc18996d4aff4d4ea43ff175353f49b2e3a05f9ec9764dc4a3c3ab444debe2c3384070de9014d44732162bb33ee04da187ef"
  in
  let* _hash =
    send_raw_transaction_to_delayed_inbox
      ~sc_rollup_node
      ~client
      ~l1_contracts
      ~sc_rollup_address
      ~node
      raw_transfer
  in
  (* Bake a few blocks, should be enough for the tx to time out and be
     forced *)
  let* _ =
    repeat 5 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  let* sender_balance_next = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_next = Eth_cli.balance ~account:receiver ~endpoint in
  Check.((sender_balance_prev <> sender_balance_next) Wei.typ)
    ~error_msg:"Balance should be updated" ;
  Check.((receiver_balance_prev <> receiver_balance_next) Wei.typ)
    ~error_msg:"Balance should be updated" ;
  Check.((sender_balance_prev > sender_balance_next) Wei.typ)
    ~error_msg:"Expected a smaller balance" ;
  Check.((receiver_balance_next > receiver_balance_prev) Wei.typ)
    ~error_msg:"Expected a bigger balance" ;
  unit

let test_delayed_transfer_timeout_fails_l1_levels =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"; "timeout"; "min_levels"]
    ~title:"Delayed transaction timeout considers l1 level"
    ~uses
  @@ fun protocol ->
  let* {
         client;
         node;
         l1_contracts;
         sc_rollup_address;
         sc_rollup_node;
         sequencer;
         proxy;
       } =
    setup_sequencer
      ~delayed_inbox_timeout:3
      ~delayed_inbox_min_levels:20
      protocol
  in
  (* Kill the sequencer *)
  let* () = Evm_node.terminate sequencer in
  let endpoint = Evm_node.endpoint proxy in
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  let sender = Eth_account.bootstrap_accounts.(0).address in
  let _ = Rpc.block_number proxy in
  let receiver = Eth_account.bootstrap_accounts.(1).address in
  let* sender_balance_prev = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_prev = Eth_cli.balance ~account:receiver ~endpoint in
  (* This is a transfer from Eth_account.bootstrap_accounts.(0) to
     Eth_account.bootstrap_accounts.(1). *)
  let raw_transfer =
    "f86d80843b9aca00825b0494b53dc01974176e5dff2298c5a94343c2585e3c54880de0b6b3a764000080820a96a07a3109107c6bd1d555ce70d6253056bc18996d4aff4d4ea43ff175353f49b2e3a05f9ec9764dc4a3c3ab444debe2c3384070de9014d44732162bb33ee04da187ef"
  in
  let* _hash =
    send_raw_transaction_to_delayed_inbox
      ~sc_rollup_node
      ~client
      ~l1_contracts
      ~sc_rollup_address
      ~node
      raw_transfer
  in
  (* Bake a few blocks, should be enough for the tx to time out in terms
     of wall time, but not in terms of L1 levels.
     Note that this test is almost the same as the one where the tx
     times out, only difference being the value of [delayed_inbox_min_levels].
  *)
  let* _ =
    repeat 5 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  let* sender_balance_next = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_next = Eth_cli.balance ~account:receiver ~endpoint in
  Check.((sender_balance_prev = sender_balance_next) Wei.typ)
    ~error_msg:"Balance should be the same" ;
  Check.((receiver_balance_prev = receiver_balance_next) Wei.typ)
    ~error_msg:"Balance should be same" ;
  Check.((sender_balance_prev = sender_balance_next) Wei.typ)
    ~error_msg:"Expected equal balance" ;
  Check.((receiver_balance_next = receiver_balance_prev) Wei.typ)
    ~error_msg:"Expected equal balance" ;
  (* Wait until it's forced *)
  let* _ =
    repeat 15 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  let* sender_balance_next = Eth_cli.balance ~account:sender ~endpoint in
  let* receiver_balance_next = Eth_cli.balance ~account:receiver ~endpoint in
  Check.((sender_balance_prev <> sender_balance_next) Wei.typ)
    ~error_msg:"Balance should be updated" ;
  Check.((receiver_balance_prev <> receiver_balance_next) Wei.typ)
    ~error_msg:"Balance should be updated" ;
  Check.((sender_balance_prev > sender_balance_next) Wei.typ)
    ~error_msg:"Expected a smaller balance" ;
  Check.((receiver_balance_next > receiver_balance_prev) Wei.typ)
    ~error_msg:"Expected a bigger balance" ;
  unit

(** This tests the situation where force kernel upgrade happens too soon. *)
let test_force_kernel_upgrade_too_early =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "upgrade"; "force"]
    ~title:"Force kernel upgrade fail too early"
    ~uses:(fun protocol -> Constant.WASM.ghostnet_evm_kernel :: uses protocol)
  @@ fun protocol ->
  (* Add a delay between first block and activation timestamp. *)
  let genesis_timestamp =
    Client.(At (Time.of_notation_exn "2020-01-10T00:00:00Z"))
  in
  let* {
         sc_rollup_node;
         l1_contracts;
         sc_rollup_address;
         client;
         sequencer;
         node;
         _;
       } =
    setup_sequencer ~genesis_timestamp ~time_between_blocks:Nothing protocol
  in
  (* Wait for the sequencer to publish its genesis block. *)
  let* () =
    repeat 3 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  let* proxy =
    Evm_node.init
      ~mode:(Proxy {devmode = true})
      (Sc_rollup_node.endpoint sc_rollup_node)
  in

  (* Assert the kernel version is the same at start up. *)
  let*@ sequencer_kernelVersion = Rpc.tez_kernelVersion sequencer in
  let*@ proxy_kernelVersion = Rpc.tez_kernelVersion proxy in
  Check.((sequencer_kernelVersion = proxy_kernelVersion) string)
    ~error_msg:"Kernel versions should be the same at start up" ;

  (* Activation timestamp is 1 day after the genesis. Therefore, it cannot
     be forced now. *)
  let activation_timestamp = "2020-01-11T00:00:00Z" in
  (* Sends the upgrade to L1 and sequencer. *)
  let* () =
    upgrade
      ~sc_rollup_node
      ~sc_rollup_address
      ~admin:Constant.bootstrap1.public_key_hash
      ~admin_contract:l1_contracts.admin
      ~client
      ~upgrade_to:Constant.WASM.ghostnet_evm_kernel
      ~activation_timestamp
      ~evm_node:(Some sequencer)
  in

  (* Now we try force the kernel upgrade via an external message. *)
  let* () =
    force_kernel_upgrade ~sc_rollup_address ~sc_rollup_node ~node ~client
  in

  (* Assert the kernel version are still the same. *)
  let*@ sequencer_kernelVersion = Rpc.tez_kernelVersion sequencer in
  let*@ new_proxy_kernelVersion = Rpc.tez_kernelVersion proxy in
  Check.((sequencer_kernelVersion = new_proxy_kernelVersion) string)
    ~error_msg:"The force kernel ugprade should have failed" ;
  unit

(** This tests the situation where the kernel does not produce blocks but
    still can be forced to upgrade via an external message. *)
let test_force_kernel_upgrade =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "upgrade"; "force"]
    ~title:"Force kernel upgrade"
    ~uses:(fun protocol -> Constant.WASM.ghostnet_evm_kernel :: uses protocol)
  @@ fun protocol ->
  (* Add a delay between first block and activation timestamp. *)
  let genesis_timestamp =
    Client.(At (Time.of_notation_exn "2020-01-10T00:00:00Z"))
  in
  let* {
         sc_rollup_node;
         l1_contracts;
         sc_rollup_address;
         client;
         sequencer;
         node;
         _;
       } =
    setup_sequencer ~genesis_timestamp ~time_between_blocks:Nothing protocol
  in
  (* Wait for the sequencer to publish its genesis block. *)
  let* () =
    repeat 3 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  let* proxy =
    Evm_node.init
      ~mode:(Proxy {devmode = true})
      (Sc_rollup_node.endpoint sc_rollup_node)
  in

  (* Assert the kernel version is the same at start up. *)
  let*@ sequencer_kernelVersion = Rpc.tez_kernelVersion sequencer in
  let*@ proxy_kernelVersion = Rpc.tez_kernelVersion proxy in
  Check.((sequencer_kernelVersion = proxy_kernelVersion) string)
    ~error_msg:"Kernel versions should be the same at start up" ;

  (* Activation timestamp is 1 day before the genesis. Therefore, it can
     be forced immediatly. *)
  let activation_timestamp = "2020-01-09T00:00:00Z" in
  (* Sends the upgrade to L1 and sequencer. *)
  let* () =
    upgrade
      ~sc_rollup_node
      ~sc_rollup_address
      ~admin:Constant.bootstrap1.public_key_hash
      ~admin_contract:l1_contracts.admin
      ~client
      ~upgrade_to:Constant.WASM.ghostnet_evm_kernel
      ~activation_timestamp
      ~evm_node:(Some sequencer)
  in

  (* We bake a few blocks. As the sequencer is not producing anything, the
     kernel will not upgrade. *)
  let* () =
    repeat 5 (fun () ->
        let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
        unit)
  in
  (* Assert the kernel version is the same, it proves the upgrade did not
      happen. *)
  let*@ sequencer_kernelVersion = Rpc.tez_kernelVersion sequencer in
  let*@ proxy_kernelVersion = Rpc.tez_kernelVersion proxy in
  Check.((sequencer_kernelVersion = proxy_kernelVersion) string)
    ~error_msg:"Kernel versions should be the same even after the message" ;

  (* Now we force the kernel upgrade via an external message. They will
     become unsynchronised. *)
  let* () =
    force_kernel_upgrade ~sc_rollup_address ~sc_rollup_node ~node ~client
  in

  (* Assert the kernel version are now different, it shows that only the rollup
     node upgraded. *)
  let*@ sequencer_kernelVersion = Rpc.tez_kernelVersion sequencer in
  let*@ new_proxy_kernelVersion = Rpc.tez_kernelVersion proxy in
  Check.((sequencer_kernelVersion <> new_proxy_kernelVersion) string)
    ~error_msg:"Kernel versions should be different after forced upgrade" ;
  Check.((sequencer_kernelVersion = proxy_kernelVersion) string)
    ~error_msg:"Sequencer should be on the previous version" ;
  unit

let test_external_transaction_to_delayed_inbox_fails =
  Protocol.register_test
    ~__FILE__
    ~tags:["evm"; "sequencer"; "delayed_inbox"; "external"]
    ~title:"Sending an external transaction to the delayed inbox fails"
    ~uses
  @@ fun protocol ->
  (* Start the evm node *)
  let* {client; node; sequencer; proxy; sc_rollup_node; _} =
    setup_sequencer
      protocol
      ~time_between_blocks:Nothing
      ~config:(`Path (kernel_inputs_path ^ "/100-inputs-for-proxy-config.yaml"))
  in
  let* () = Evm_node.wait_for_blueprint_injected ~timeout:5. sequencer 0 in
  (* Bake a couple more levels for the blueprint to be final *)
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  let* _ = next_rollup_node_level ~sc_rollup_node ~node ~client in
  let raw_tx, _ = read_tx_from_file () |> List.hd in
  let*@ tx_hash = Rpc.send_raw_transaction ~raw_tx proxy in
  (* Bake enough levels to make sure the transaction would be processed
     if added *)
  let* () =
    repeat 10 (fun () ->
        let* _ = Rpc.produce_block sequencer in
        let* _ = next_rollup_node_level ~node ~client ~sc_rollup_node in
        unit)
  in
  (* Response should be none *)
  let*@ response = Rpc.get_transaction_receipt ~tx_hash proxy in
  assert (Option.is_none response) ;
  let*@ response = Rpc.get_transaction_receipt ~tx_hash sequencer in
  assert (Option.is_none response) ;
  unit

let () =
  test_remove_sequencer [Alpha] ;
  test_persistent_state [Alpha] ;
  test_publish_blueprints [Alpha] ;
  test_resilient_to_rollup_node_disconnect [Alpha] ;
  test_can_fetch_smart_rollup_address [Alpha] ;
  test_can_fetch_blueprint [Alpha] ;
  test_send_transaction_to_delayed_inbox [Alpha] ;
  test_send_deposit_to_delayed_inbox [Alpha] ;
  test_rpc_produceBlock [Alpha] ;
  test_delayed_transfer_is_included [Alpha] ;
  test_delayed_deposit_is_included [Alpha] ;
  test_init_from_rollup_node_data_dir [Alpha] ;
  test_observer_applies_blueprint [Alpha] ;
  test_upgrade_kernel_unsync [Alpha] ;
  test_upgrade_kernel_sync [Alpha] ;
  test_force_kernel_upgrade [Alpha] ;
  test_force_kernel_upgrade_too_early [Alpha] ;
  test_external_transaction_to_delayed_inbox_fails [Alpha] ;
  test_delayed_transfer_timeout [Alpha] ;
  test_delayed_transfer_timeout_fails_l1_levels [Alpha]
