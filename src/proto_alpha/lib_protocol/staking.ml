(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Alpha_context

let stake ctxt ~sender ~delegate amount =
  Token.transfer
    ctxt
    (`Contract (Contract.Implicit sender))
    (`Frozen_deposits delegate)
    amount

let finalize_unstake ctxt pkh =
  let open Lwt_result_syntax in
  let contract = Contract.Implicit pkh in
  let* ctxt, finalizable =
    Unstake_requests
    .prepare_finalize_unstake_and_save_remaining_unfinalizable_requests
      ctxt
      contract
  in
  List.fold_left_es
    (fun (ctxt, balance_updates) (delegate, cycle, amount) ->
      let+ ctxt, new_balance_updates =
        Token.transfer
          ctxt
          (`Unstaked_frozen_deposits (delegate, cycle))
          (`Contract contract)
          amount
      in
      (ctxt, new_balance_updates @ balance_updates))
    (ctxt, [])
    finalizable

let punish_delegate ctxt delegate level mistake ~rewarded =
  let open Lwt_result_syntax in
  let punish =
    match mistake with
    | `Double_baking -> Delegate.punish_double_baking
    | `Double_endorsing -> Delegate.punish_double_endorsing
  in
  let* ctxt, {staked; unstaked} = punish ctxt delegate level in
  let init_to_burn_to_reward =
    let Delegate.{amount_to_burn; reward} = staked in
    let giver = `Frozen_deposits delegate in
    ([(giver, amount_to_burn)], [(giver, reward)])
  in
  let to_burn, to_reward =
    List.fold_left
      (fun (to_burn, to_reward) (cycle, Delegate.{amount_to_burn; reward}) ->
        let giver = `Unstaked_frozen_deposits (delegate, cycle) in
        ((giver, amount_to_burn) :: to_burn, (giver, reward) :: to_reward))
      init_to_burn_to_reward
      unstaked
  in
  let* ctxt, punish_balance_updates =
    Token.transfer_n ctxt to_burn `Double_signing_punishments
  in
  let+ ctxt, reward_balance_updates =
    Token.transfer_n ctxt to_reward (`Contract rewarded)
  in
  (ctxt, reward_balance_updates @ punish_balance_updates)
