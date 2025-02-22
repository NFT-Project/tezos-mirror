(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
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

let join_errors e1 e2 =
  let open Lwt_result_syntax in
  match (e1, e2) with
  | Ok (), Ok () -> return_unit
  | Error e, Ok () | Ok (), Error e -> fail e
  | Error e1, Error e2 -> fail (e1 @ e2)

(** Tez manipulation module *)
module Tez = struct
  include Protocol.Alpha_context.Tez

  let ( + ) a b =
    let open Lwt_result_wrap_syntax in
    let*?@ s = a +? b in
    return s

  let ( - ) a b =
    let open Lwt_result_wrap_syntax in
    let*?@ s = a -? b in
    return s

  let ( +! ) a b =
    let a = to_mutez a in
    let b = to_mutez b in
    Int64.add a b |> of_mutez_exn

  let ( -! ) a b =
    let a = to_mutez a in
    let b = to_mutez b in
    Int64.sub a b |> of_mutez_exn

  let of_mutez = of_mutez_exn

  let of_z a = Z.to_int64 a |> of_mutez

  let of_q ~round_up Q.{num; den} =
    (if round_up then Z.cdiv num den else Z.div num den) |> of_z

  let ratio num den =
    Q.make (Z.of_int64 (to_mutez num)) (Z.of_int64 (to_mutez den))

  let mul_q tez portion =
    let tez_z = to_mutez tez |> Z.of_int64 in
    Q.(mul portion ~$$tez_z)
end

(** Representation of Tez with non integer values *)
module Partial_tez = struct
  include Q

  let of_tez a = Tez.to_mutez a |> of_int64

  let to_tez_rem {num; den} =
    let tez, rem = Z.div_rem num den in
    (Tez.of_z tez, rem /// den)

  let to_tez ~round_up = Tez.of_q ~round_up

  let get_rem a = snd (to_tez_rem a)

  let pp fmt a =
    let tez, rem = to_tez_rem a in
    (* If rem = 0, we keep the (+ 0), to indicate that it's a partial tez *)
    Format.fprintf fmt "%a ( +%aµꜩ )" Tez.pp tez Q.pp_print rem
end

module Cycle = Protocol.Alpha_context.Cycle

(** [Frozen_tez] represents frozen stake and frozen unstaked funds.
    Properties:
    - sum of all current partial tez is an integer
    - Can only add integer amounts
    - Can always subtract integer amount (if lower than frozen amount)
    - If subtracting partial amount, must be the whole frozen amount (for given contract).
      The remainder is then distributed equally amongst remaining accounts, to keep property 1.
    - All entries of current are positive, non zero.
*)
module Frozen_tez = struct
  (* The map in current maps the stakers' name with their staked value.
     It contains only delegators of the delegate which owns the frozen tez *)
  type t = {
    delegate : string;
    initial : Tez.t;
    self_current : Tez.t;
    co_current : Partial_tez.t String.Map.t;
  }

  let zero =
    {
      delegate = "";
      initial = Tez.zero;
      self_current = Tez.zero;
      co_current = String.Map.empty;
    }

  let init amount account delegate =
    if account = delegate then
      {
        delegate;
        initial = amount;
        self_current = amount;
        co_current = String.Map.empty;
      }
    else
      {
        delegate;
        initial = amount;
        self_current = Tez.zero;
        co_current = String.Map.singleton account (Partial_tez.of_tez amount);
      }

  let union a b =
    assert (a.delegate = b.delegate) ;
    {
      delegate = a.delegate;
      initial = Tez.(a.initial +! b.initial);
      self_current = Tez.(a.self_current +! b.self_current);
      co_current =
        String.Map.union
          (fun _ x y -> Some Partial_tez.(x + y))
          a.co_current
          b.co_current;
    }

  let get account frozen_tez =
    if account = frozen_tez.delegate then
      Partial_tez.of_tez frozen_tez.self_current
    else
      match String.Map.find account frozen_tez.co_current with
      | None -> Partial_tez.zero
      | Some p -> p

  let total_co_current_q co_current =
    String.Map.fold
      (fun _ x acc -> Partial_tez.(x + acc))
      co_current
      Partial_tez.zero

  let total_current a =
    let r = total_co_current_q a.co_current in
    let tez, rem = Partial_tez.to_tez_rem r in
    assert (Q.(equal rem zero)) ;
    Tez.(tez +! a.self_current)

  let add_q_to_all_co_current quantity co_current =
    let s = total_co_current_q co_current in
    let f p_amount =
      let q = Q.div p_amount s in
      Partial_tez.add p_amount (Q.mul quantity q)
    in
    String.Map.map f co_current

  (* For rewards, distribute equally *)
  let add_tez_to_all_current tez a =
    let self_portion = Tez.ratio a.self_current (total_current a) in
    let self_quantity = Tez.mul_q tez self_portion |> Tez.of_q ~round_up:true in
    let co_quantity = Partial_tez.of_tez Tez.(tez -! self_quantity) in
    let co_current = add_q_to_all_co_current co_quantity a.co_current in
    {a with co_current; self_current = Tez.(a.self_current +! self_quantity)}

  (* For slashing, slash equally *)
  let sub_tez_from_all_current tez a =
    let self_portion = Tez.ratio a.self_current (total_current a) in
    let self_quantity =
      Tez.mul_q tez self_portion |> Tez.of_q ~round_up:false
    in
    let self_current =
      if Tez.(self_quantity >= a.self_current) then Tez.zero
      else Tez.(a.self_current -! self_quantity)
    in
    let co_quantity = Tez.(tez -! self_quantity) in
    let s = total_co_current_q a.co_current in
    if Partial_tez.(geq (of_tez co_quantity) s) then
      {a with self_current; co_current = String.Map.empty}
    else
      let f p_amount =
        let q = Q.div p_amount s in
        Partial_tez.sub p_amount (Tez.mul_q co_quantity q)
        (* > 0 *)
      in
      {a with self_current; co_current = String.Map.map f a.co_current}

  (* Adds frozen to account. Happens each stake in frozen deposits *)
  let add_current amount account a =
    if account = a.delegate then
      {a with self_current = Tez.(a.self_current +! amount)}
    else
      {
        a with
        co_current =
          String.Map.update
            account
            (function
              | None -> Some (Partial_tez.of_tez amount)
              | Some q -> Some Partial_tez.(add q (of_tez amount)))
            a.co_current;
      }

  (* Adds frozen to account. Happens each unstake to unstaked frozen deposits *)
  let add_init amount account a = union a (init amount account a.delegate)

  (* Allows amount greater than current frozen amount.
     Happens each unstake in frozen deposits *)
  let sub_current amount account a =
    if account = a.delegate then
      let amount = Tez.min amount a.self_current in
      ({a with self_current = Tez.(a.self_current -! amount)}, amount)
    else
      match String.Map.find account a.co_current with
      | None -> (a, Tez.zero)
      | Some frozen ->
          let amount_q = Partial_tez.of_tez amount in
          if Q.(geq amount_q frozen) then
            let removed, remainder = Partial_tez.to_tez_rem frozen in
            let co_current = String.Map.remove account a.co_current in
            let co_current = add_q_to_all_co_current remainder co_current in
            ({a with co_current}, removed)
          else
            let co_current =
              String.Map.add account Q.(frozen - amount_q) a.co_current
            in
            ({a with co_current}, amount)

  let sub_current_and_init amount account a =
    let a, amount = sub_current amount account a in
    ({a with initial = Tez.(a.initial -! amount)}, amount)

  let slash base_amount (pct : Protocol.Percentage.t) a =
    let pct_q = Protocol.Percentage.to_q pct in
    let slashed_amount =
      Tez.mul_q base_amount pct_q |> Tez.of_q ~round_up:false
    in
    let total_current = total_current a in
    let slashed_amount_final = Tez.min slashed_amount total_current in
    (sub_tez_from_all_current slashed_amount a, slashed_amount_final)
end

(** Representation of Unstaked frozen deposits *)
module Unstaked_frozen = struct
  type r = {
    cycle : Cycle.t;
    (* initial total requested amount (slash ∝ initial) *)
    initial : Tez.t;
    (* current amount, slashes applied here *)
    current : Tez.t;
    (* initial requests, don't apply slash unless finalize or balance query *)
    requests : Tez.t String.Map.t;
    (* slash pct memory for requests *)
    slash_pct : int;
  }

  type t = r list

  type get_info = {cycle : Cycle.t; request : Tez.t; current : Tez.t}

  type get_info_list = get_info list

  type finalizable_info = {
    amount : Tez.t;
    slashed_requests : Tez.t String.Map.t;
  }

  let zero = []

  let init_r cycle request account =
    {
      cycle;
      initial = request;
      current = request;
      requests = String.Map.singleton account request;
      slash_pct = 0;
    }

  let apply_slash_to_request slash_pct amount =
    let slashed_amount =
      Tez.mul_q amount Q.(slash_pct // 100) |> Tez.of_q ~round_up:true
    in
    Tez.(amount -! slashed_amount)

  let apply_slash_to_current slash_pct initial current =
    let slashed_amount =
      Tez.mul_q initial Q.(slash_pct // 100) |> Tez.of_q ~round_up:false
    in
    Tez.sub_opt current slashed_amount |> Option.value ~default:Tez.zero

  let remove_zeros (a : t) : t =
    List.filter (fun ({current; _} : r) -> Tez.(current > zero)) a

  let get account unstaked : get_info_list =
    List.filter_map
      (fun {cycle; requests; slash_pct; _} ->
        String.Map.find account requests
        |> Option.map (fun request ->
               {
                 cycle;
                 request;
                 current = apply_slash_to_request slash_pct request;
               }))
      unstaked

  let get_total account unstaked =
    get account unstaked
    |> List.fold_left
         (fun acc ({current; _} : get_info) -> Tez.(acc +! current))
         Tez.zero

  let sum_current unstaked =
    List.fold_left
      (fun acc ({current; _} : r) -> Tez.(acc +! current))
      Tez.zero
      unstaked

  (* Happens each unstake operation *)
  let rec add_unstake cycle amount account : t -> t = function
    | [] -> [init_r cycle amount account]
    | ({cycle = c; requests; initial; current; slash_pct} as h) :: t ->
        let open Tez in
        if Cycle.equal c cycle then (
          assert (Int.equal slash_pct 0) ;
          {
            cycle;
            initial = initial +! amount;
            current = current +! amount;
            slash_pct;
            requests =
              String.Map.update
                account
                (function
                  | None -> Some amount | Some x -> Some Tez.(x +! amount))
                requests;
          }
          :: t)
        else h :: add_unstake cycle amount account t

  (* Happens in stake from unstake *)
  let sub_unstake amount account : r -> r =
   fun {cycle; requests; initial; current; slash_pct} ->
    assert (slash_pct = 0) ;
    let open Tez in
    {
      cycle;
      initial = initial -! amount;
      current = current -! amount;
      slash_pct;
      requests =
        String.Map.update
          account
          (function
            | None ->
                assert (Tez.(amount = zero)) ;
                None
            | Some x ->
                if Tez.(x = amount) then None else Some Tez.(x -! amount))
          requests;
    }

  (* Makes given cycle finalizable (and unslashable) *)
  let rec pop_cycle cycle : t -> finalizable_info * t = function
    | [] -> ({amount = Tez.zero; slashed_requests = String.Map.empty}, [])
    | ({cycle = c; requests; initial = _; current; slash_pct} as h) :: t ->
        if Cycle.(c = cycle) then
          let amount = current in
          let slashed_requests =
            String.Map.map (apply_slash_to_request slash_pct) requests
          in
          ({amount; slashed_requests}, t)
        else if Cycle.(c < cycle) then
          Stdlib.failwith
            "Unstaked_frozen: found unfinalized cycle before given [cycle]. \
             Make sure to call [apply_unslashable] every cycle"
        else
          let info, rest = pop_cycle cycle t in
          (info, h :: rest)

  let slash ~slashable_deposits_period slashed_cycle pct_times_100 a =
    remove_zeros a
    |> List.map
         (fun
           ({cycle; requests = _; initial; current; slash_pct = old_slash_pct}
           as r)
         ->
           if
             Cycle.(
               cycle > slashed_cycle
               || add cycle slashable_deposits_period < slashed_cycle)
           then (r, Tez.zero)
           else
             let new_current =
               apply_slash_to_current pct_times_100 initial current
             in
             let slashed = Tez.(current -! new_current) in
             let slash_pct = min 100 (pct_times_100 + old_slash_pct) in
             ({r with slash_pct; current = new_current}, slashed))
    |> List.split
end

(** Representation of unstaked finalizable tez *)
module Unstaked_finalizable = struct
  (* Slashing might put inaccessible tez in this container: they are represented in the remainder.
     They still count towards the total supply, but are currently owned by noone.
     At most one mutez per unstaking account per slashed cycle *)
  type t = {map : Tez.t String.Map.t; remainder : Tez.t}

  let zero = {map = String.Map.empty; remainder = Tez.zero}

  (* Called when unstaked frozen for some cycle becomes finalizable *)
  let add_from_poped_ufd
      ({amount; slashed_requests} : Unstaked_frozen.finalizable_info)
      {map; remainder} =
    let total_requested =
      String.Map.fold (fun _ x acc -> Tez.(x +! acc)) slashed_requests Tez.zero
    in
    let remainder = Tez.(remainder +! amount -! total_requested) in
    let map =
      String.Map.union (fun _ a b -> Some Tez.(a +! b)) map slashed_requests
    in
    {map; remainder}

  let total {map; remainder} =
    String.Map.fold (fun _ x acc -> Tez.(x +! acc)) map remainder

  let get account {map; _} =
    match String.Map.find account map with None -> Tez.zero | Some x -> x
end

(** Abstraction of the staking parameters for tests *)
type staking_parameters = {
  limit_of_staking_over_baking : Q.t;
  edge_of_baking_over_staking : Q.t;
}

module CycleMap = Map.Make (Cycle)

(** Abstract information of accounts *)
type account_state = {
  pkh : Signature.Public_key_hash.t;
  contract : Protocol.Alpha_context.Contract.t;
  delegate : string option;
  parameters : staking_parameters;
  liquid : Tez.t;
  bonds : Tez.t;
  (* The three following fields contain maps from the account's stakers to,
     respectively, their frozen stake, their unstaked frozen balance, and
     their unstaked finalizable funds. Additionally, [unstaked_frozen] indexes
     the maps with the cycle at which the unstake operation occurred. *)
  frozen_deposits : Frozen_tez.t;
  unstaked_frozen : Unstaked_frozen.t;
  unstaked_finalizable : Unstaked_finalizable.t;
  staking_delegator_numerator : Z.t;
  staking_delegate_denominator : Z.t;
  frozen_rights : Tez.t CycleMap.t;
  slashed_cycles : Cycle.t list;
}

let init_account ?delegate ~pkh ~contract ~parameters ?(liquid = Tez.zero)
    ?(bonds = Tez.zero) ?(frozen_deposits = Frozen_tez.zero)
    ?(unstaked_frozen = Unstaked_frozen.zero)
    ?(unstaked_finalizable = Unstaked_finalizable.zero)
    ?(staking_delegator_numerator = Z.zero)
    ?(staking_delegate_denominator = Z.zero) ?(frozen_rights = CycleMap.empty)
    ?(slashed_cycles = []) () =
  {
    pkh;
    contract;
    delegate;
    parameters;
    liquid;
    bonds;
    frozen_deposits;
    unstaked_frozen;
    unstaked_finalizable;
    staking_delegator_numerator;
    staking_delegate_denominator;
    frozen_rights;
    slashed_cycles;
  }

type account_map = account_state String.Map.t

(** Balance returned by RPCs. Partial tez are rounded down *)
type balance = {
  liquid_b : Tez.t;
  bonds_b : Tez.t;
  staked_b : Partial_tez.t;
  unstaked_frozen_b : Tez.t;
  unstaked_finalizable_b : Tez.t;
  staking_delegator_numerator_b : Z.t;
  staking_delegate_denominator_b : Z.t;
}

let balance_zero =
  {
    liquid_b = Tez.zero;
    bonds_b = Tez.zero;
    staked_b = Partial_tez.zero;
    unstaked_frozen_b = Tez.zero;
    unstaked_finalizable_b = Tez.zero;
    staking_delegator_numerator_b = Z.zero;
    staking_delegate_denominator_b = Z.zero;
  }

let balance_of_account account_name (account_map : account_map) =
  match String.Map.find account_name account_map with
  | None -> raise Not_found
  | Some
      {
        pkh = _;
        contract = _;
        delegate;
        parameters = _;
        liquid;
        bonds;
        frozen_deposits = _;
        unstaked_frozen = _;
        unstaked_finalizable = _;
        staking_delegator_numerator;
        staking_delegate_denominator;
        frozen_rights = _;
        slashed_cycles = _;
      } ->
      let balance =
        {
          balance_zero with
          liquid_b = liquid;
          bonds_b = bonds;
          staking_delegator_numerator_b = staking_delegator_numerator;
          staking_delegate_denominator_b = staking_delegate_denominator;
        }
      in
      let balance =
        match delegate with
        | None -> balance
        | Some d -> (
            match String.Map.find d account_map with
            | None -> raise Not_found
            | Some delegate_account ->
                {
                  balance with
                  staked_b =
                    Frozen_tez.get account_name delegate_account.frozen_deposits;
                })
      in
      (* Because an account can still have frozen or finalizable funds from a delegate
         that is not its own, we iterate over all of them *)
      let unstaked_frozen_b, unstaked_finalizable_b =
        String.Map.fold
          (fun _delegate_name delegate (frozen, finalzbl) ->
            let frozen =
              Tez.(
                frozen
                +! Unstaked_frozen.get_total
                     account_name
                     delegate.unstaked_frozen)
            in
            let finalzbl =
              Tez.(
                finalzbl
                +! Unstaked_finalizable.get
                     account_name
                     delegate.unstaked_finalizable)
            in
            (frozen, finalzbl))
          account_map
          (Tez.zero, Tez.zero)
      in
      {balance with unstaked_frozen_b; unstaked_finalizable_b}

let balance_pp fmt
    {
      liquid_b;
      bonds_b;
      staked_b;
      unstaked_frozen_b;
      unstaked_finalizable_b;
      staking_delegator_numerator_b;
      staking_delegate_denominator_b;
    } =
  Format.fprintf
    fmt
    "{@;\
     @[<v 2>  liquid : %a@;\
     bonds : %a@;\
     staked : %a@;\
     unstaked_frozen : %a@;\
     unstaked_finalizable : %a@;\
     staking_delegator_numerator : %a@;\
     staking_delegate_denominator : %a@;\
     }@."
    Tez.pp
    liquid_b
    Tez.pp
    bonds_b
    Partial_tez.pp
    staked_b
    Tez.pp
    unstaked_frozen_b
    Tez.pp
    unstaked_finalizable_b
    Z.pp_print
    staking_delegator_numerator_b
    Z.pp_print
    staking_delegate_denominator_b

let balance_update_pp fmt
    ( {
        liquid_b = a_liquid_b;
        bonds_b = a_bonds_b;
        staked_b = a_staked_b;
        unstaked_frozen_b = a_unstaked_frozen_b;
        unstaked_finalizable_b = a_unstaked_finalizable_b;
        staking_delegator_numerator_b = a_staking_delegator_numerator_b;
        staking_delegate_denominator_b = a_staking_delegate_denominator_b;
      },
      {
        liquid_b = b_liquid_b;
        bonds_b = b_bonds_b;
        staked_b = b_staked_b;
        unstaked_frozen_b = b_unstaked_frozen_b;
        unstaked_finalizable_b = b_unstaked_finalizable_b;
        staking_delegator_numerator_b = b_staking_delegator_numerator_b;
        staking_delegate_denominator_b = b_staking_delegate_denominator_b;
      } ) =
  Format.fprintf
    fmt
    "{@;\
     @[<v 2>  liquid : %a -> %a@;\
     bonds : %a -> %a@;\
     staked : %a -> %a@;\
     unstaked_frozen : %a -> %a@;\
     unstaked_finalizable : %a -> %a@;\
     staking_delegator_numerator : %a -> %a@;\
     staking_delegate_denominator : %a -> %a@;\
     }@."
    Tez.pp
    a_liquid_b
    Tez.pp
    b_liquid_b
    Tez.pp
    a_bonds_b
    Tez.pp
    b_bonds_b
    Partial_tez.pp
    a_staked_b
    Partial_tez.pp
    b_staked_b
    Tez.pp
    a_unstaked_frozen_b
    Tez.pp
    b_unstaked_frozen_b
    Tez.pp
    a_unstaked_finalizable_b
    Tez.pp
    b_unstaked_finalizable_b
    Z.pp_print
    a_staking_delegator_numerator_b
    Z.pp_print
    b_staking_delegator_numerator_b
    Z.pp_print
    a_staking_delegate_denominator_b
    Z.pp_print
    b_staking_delegate_denominator_b

let assert_balance_equal ~loc account_name
    {
      liquid_b = a_liquid_b;
      bonds_b = a_bonds_b;
      staked_b = a_staked_b;
      unstaked_frozen_b = a_unstaked_frozen_b;
      unstaked_finalizable_b = a_unstaked_finalizable_b;
      staking_delegator_numerator_b = a_staking_delegator_numerator_b;
      staking_delegate_denominator_b = a_staking_delegate_denominator_b;
    }
    {
      liquid_b = b_liquid_b;
      bonds_b = b_bonds_b;
      staked_b = b_staked_b;
      unstaked_frozen_b = b_unstaked_frozen_b;
      unstaked_finalizable_b = b_unstaked_finalizable_b;
      staking_delegator_numerator_b = b_staking_delegator_numerator_b;
      staking_delegate_denominator_b = b_staking_delegate_denominator_b;
    } =
  let open Lwt_result_syntax in
  let f s = Format.asprintf "%s: %s" account_name s in
  let* () =
    List.fold_left
      (fun a b ->
        let*! a in
        let*! b in
        join_errors a b)
      return_unit
      [
        Assert.equal
          ~loc
          Tez.equal
          (f "Liquid balances do not match")
          Tez.pp
          a_liquid_b
          b_liquid_b;
        Assert.equal
          ~loc
          Tez.equal
          (f "Bonds balances do not match")
          Tez.pp
          a_bonds_b
          b_bonds_b;
        Assert.equal
          ~loc
          Tez.equal
          (f "Staked balances do not match")
          Tez.pp
          (Partial_tez.to_tez ~round_up:false a_staked_b)
          (Partial_tez.to_tez ~round_up:false b_staked_b);
        Assert.equal
          ~loc
          Tez.equal
          (f "Unstaked frozen balances do not match")
          Tez.pp
          a_unstaked_frozen_b
          b_unstaked_frozen_b;
        Assert.equal
          ~loc
          Tez.equal
          (f "Unstaked finalizable balances do not match")
          Tez.pp
          a_unstaked_finalizable_b
          b_unstaked_finalizable_b;
        Assert.equal
          ~loc
          Z.equal
          (f "Staking delegator numerators do not match")
          Z.pp_print
          a_staking_delegator_numerator_b
          b_staking_delegator_numerator_b;
        Assert.equal
          ~loc
          Z.equal
          (f "Staking delegate denominators do not match")
          Z.pp_print
          a_staking_delegate_denominator_b
          b_staking_delegate_denominator_b;
      ]
  in
  return_unit

let update_account ~f account_name account_map =
  String.Map.update
    account_name
    (function None -> raise Not_found | Some x -> Some (f x))
    account_map

let add_liquid_rewards amount account_name account_map =
  let f account =
    let liquid = Tez.(account.liquid +! amount) in
    {account with liquid}
  in
  update_account ~f account_name account_map

let add_frozen_rewards amount account_name account_map =
  let f account =
    let frozen_deposits =
      Frozen_tez.add_tez_to_all_current amount account.frozen_deposits
    in
    {account with frozen_deposits}
  in
  update_account ~f account_name account_map

let apply_burn amount src_name account_map =
  let f src = {src with liquid = Tez.(src.liquid -! amount)} in
  update_account ~f src_name account_map

let apply_transfer amount src_name dst_name account_map =
  match
    (String.Map.find src_name account_map, String.Map.find dst_name account_map)
  with
  | Some src, Some _ ->
      if Tez.(src.liquid < amount) then
        (* Invalid amount: operation will fail *)
        account_map
      else
        let f_src src =
          let liquid = Tez.(src.liquid -! amount) in
          {src with liquid}
        in
        let f_dst dst =
          let liquid = Tez.(dst.liquid +! amount) in
          {dst with liquid}
        in
        let account_map = update_account ~f:f_src src_name account_map in
        update_account ~f:f_dst dst_name account_map
  | _ -> raise Not_found

let stake_from_unstake amount current_cycle consensus_rights_delay delegate_name
    account_map =
  match String.Map.find delegate_name account_map with
  | None -> raise Not_found
  | Some ({unstaked_frozen; frozen_deposits; slashed_cycles; _} as account) ->
      let oldest_slashable_cycle =
        Cycle.(sub current_cycle (consensus_rights_delay + 1))
        |> Option.value ~default:Cycle.root
      in
      if
        List.exists
          (fun x -> Cycle.(x >= oldest_slashable_cycle))
          slashed_cycles
      then (account_map, amount)
      else
        let unstaked_frozen =
          List.sort
            (fun (Unstaked_frozen.{cycle = cycle1; _} : Unstaked_frozen.r)
                 {cycle = cycle2; _} -> Cycle.compare cycle2 cycle1)
            unstaked_frozen
        in
        let rec aux acc_unstakes rem_amount rem_unstakes =
          match rem_unstakes with
          | [] -> (acc_unstakes, rem_amount)
          | (Unstaked_frozen.{initial; _} as h) :: t ->
              if Tez.(rem_amount = zero) then
                (acc_unstakes @ rem_unstakes, Tez.zero)
              else if Tez.(rem_amount >= initial) then
                let h = Unstaked_frozen.sub_unstake initial delegate_name h in
                let rem_amount = Tez.(rem_amount -! initial) in
                aux (acc_unstakes @ [h]) rem_amount t
              else
                let h =
                  Unstaked_frozen.sub_unstake rem_amount delegate_name h
                in
                (acc_unstakes @ [h] @ t, Tez.zero)
        in
        let unstaked_frozen, rem_amount = aux [] amount unstaked_frozen in
        let frozen_deposits =
          Frozen_tez.add_current
            Tez.(amount -! rem_amount)
            delegate_name
            frozen_deposits
        in
        let account = {account with unstaked_frozen; frozen_deposits} in
        let account_map =
          update_account ~f:(fun _ -> account) delegate_name account_map
        in
        (account_map, rem_amount)

let apply_stake amount current_cycle consensus_rights_delay staker_name
    account_map =
  match String.Map.find staker_name account_map with
  | None -> raise Not_found
  | Some staker -> (
      match staker.delegate with
      | None ->
          (* Invalid operation: no delegate *)
          account_map
      | Some delegate_name ->
          let old_account_map = account_map in
          let account_map, amount =
            if delegate_name = staker_name then
              stake_from_unstake
                amount
                current_cycle
                consensus_rights_delay
                staker_name
                account_map
            else (account_map, amount)
          in
          if Tez.(staker.liquid < amount) then
            (* Invalid amount: operation will fail *)
            old_account_map
          else
            let f_staker staker =
              let liquid = Tez.(staker.liquid -! amount) in
              {staker with liquid}
            in
            let f_delegate delegate =
              let frozen_deposits =
                Frozen_tez.add_current
                  amount
                  staker_name
                  delegate.frozen_deposits
              in
              {delegate with frozen_deposits}
            in
            let account_map =
              update_account ~f:f_staker staker_name account_map
            in
            update_account ~f:f_delegate delegate_name account_map)

let apply_unstake cycle amount staker_name account_map =
  match String.Map.find staker_name account_map with
  | None -> raise Not_found
  | Some staker -> (
      match staker.delegate with
      | None -> (* Invalid operation: no delegate *) account_map
      | Some delegate_name -> (
          match String.Map.find delegate_name account_map with
          | None -> raise Not_found
          | Some delegate ->
              let frozen_deposits, amount_unstaked =
                Frozen_tez.sub_current
                  amount
                  staker_name
                  delegate.frozen_deposits
              in
              let delegate = {delegate with frozen_deposits} in
              let account_map =
                String.Map.add delegate_name delegate account_map
              in
              let f delegate =
                let unstaked_frozen =
                  Unstaked_frozen.add_unstake
                    cycle
                    amount_unstaked
                    staker_name
                    delegate.unstaked_frozen
                in
                {delegate with unstaked_frozen}
              in
              update_account ~f delegate_name account_map))

let apply_unslashable_f cycle delegate =
  let amount_unslashable, unstaked_frozen =
    Unstaked_frozen.pop_cycle cycle delegate.unstaked_frozen
  in
  let unstaked_finalizable =
    Unstaked_finalizable.add_from_poped_ufd
      amount_unslashable
      delegate.unstaked_finalizable
  in
  {delegate with unstaked_frozen; unstaked_finalizable}

(* Updates unstaked unslashable values for given account *)
let apply_unslashable cycle account_name account_map =
  update_account ~f:(apply_unslashable_f cycle) account_name account_map

(* Updates unstaked unslashable values in all accounts *)
let apply_unslashable_for_all cycle account_map =
  String.Map.map (apply_unslashable_f cycle) account_map

let apply_finalize staker_name account_map =
  match String.Map.find staker_name account_map with
  | None -> raise Not_found
  | Some _staker ->
      (* Because an account can still have finalizable funds from a delegate
         that is not its own, we iterate over all of them *)
      String.Map.fold
        (fun delegate_name delegate account_map_acc ->
          match
            String.Map.find staker_name delegate.unstaked_finalizable.map
          with
          | None -> account_map_acc
          | Some amount ->
              let f_staker staker =
                let liquid = Tez.(staker.liquid +! amount) in
                {staker with liquid}
              in
              let f_delegate delegate =
                let map =
                  String.Map.remove
                    staker_name
                    delegate.unstaked_finalizable.map
                in
                {
                  delegate with
                  unstaked_finalizable =
                    {delegate.unstaked_finalizable with map};
                }
              in
              let account_map_acc =
                update_account ~f:f_staker staker_name account_map_acc
              in
              update_account ~f:f_delegate delegate_name account_map_acc)
        account_map
        account_map

let balance_and_total_balance_of_account account_name account_map =
  let ({
         liquid_b;
         bonds_b;
         staked_b;
         unstaked_frozen_b;
         unstaked_finalizable_b;
         staking_delegator_numerator_b = _;
         staking_delegate_denominator_b = _;
       } as balance) =
    balance_of_account account_name account_map
  in
  ( balance,
    Tez.(
      liquid_b +! bonds_b
      +! Partial_tez.to_tez ~round_up:false staked_b
      +! unstaked_frozen_b +! unstaked_finalizable_b) )

let apply_slashing
    ( culprit,
      Protocol.Denunciations_repr.{rewarded; misbehaviour; operation_hash = _}
    ) constants account_map =
  let find_account_name_from_pkh_exn pkh account_map =
    match
      Option.map
        fst
        String.Map.(
          choose
          @@ filter
               (fun _ account ->
                 Signature.Public_key_hash.equal pkh account.pkh)
               account_map)
    with
    | None -> assert false
    | Some x -> x
  in
  let slashed_cycle =
    Block.current_cycle_of_level
      ~blocks_per_cycle:
        constants.Protocol.Alpha_context.Constants.Parametric.blocks_per_cycle
      ~current_level:(Protocol.Raw_level_repr.to_int32 misbehaviour.level)
  in
  let culprit_name = find_account_name_from_pkh_exn culprit account_map in
  let rewarded_name = find_account_name_from_pkh_exn rewarded account_map in
  let slashed_pct =
    match misbehaviour.kind with
    | Double_baking ->
        constants
          .Protocol.Alpha_context.Constants.Parametric
           .percentage_of_frozen_deposits_slashed_per_double_baking
    | Double_attesting ->
        constants.percentage_of_frozen_deposits_slashed_per_double_attestation
  in
  let get_total_supply acc_map =
    String.Map.fold
      (fun _name
           {
             pkh = _;
             contract = _;
             delegate = _;
             parameters = _;
             liquid;
             bonds;
             frozen_deposits;
             unstaked_frozen;
             unstaked_finalizable;
             staking_delegator_numerator = _;
             staking_delegate_denominator = _;
             frozen_rights = _;
             slashed_cycles = _;
           }
           tot ->
        Tez.(
          liquid +! bonds
          +! Frozen_tez.total_current frozen_deposits
          +! Unstaked_frozen.sum_current unstaked_frozen
          +! Unstaked_finalizable.total unstaked_finalizable
          +! tot))
      acc_map
      Tez.zero
  in
  let total_before_slash = get_total_supply account_map in
  let slash_culprit
      ({frozen_deposits; unstaked_frozen; frozen_rights; _} as acc) =
    let base_rights =
      CycleMap.find slashed_cycle frozen_rights
      |> Option.value ~default:Tez.zero
    in
    let frozen_deposits, slashed_frozen =
      Frozen_tez.slash base_rights slashed_pct frozen_deposits
    in
    let slashed_pct_q = Protocol.Percentage.to_q slashed_pct in
    let slashed_pct = Q.(100 // 1 * slashed_pct_q |> to_int) in
    let unstaked_frozen, slashed_unstaked =
      Unstaked_frozen.slash
        ~slashable_deposits_period:constants.consensus_rights_delay
        slashed_cycle
        slashed_pct
        unstaked_frozen
    in
    ( {acc with frozen_deposits; unstaked_frozen},
      slashed_frozen :: slashed_unstaked )
  in
  let culprit_account =
    String.Map.find culprit_name account_map
    |> Option.value_f ~default:(fun () -> raise Not_found)
  in
  let slashed_culprit_account, total_slashed = slash_culprit culprit_account in
  let account_map =
    update_account
      ~f:(fun _ -> slashed_culprit_account)
      culprit_name
      account_map
  in
  let total_after_slash = get_total_supply account_map in
  let portion_reward =
    constants.adaptive_issuance.global_limit_of_staking_over_baking + 2
  in
  (* For each container slashed, the snitch gets a reward transferred. It gets rounded
     down each time *)
  let reward_to_snitch =
    List.map
      (fun x -> Tez.mul_q x Q.(1 // portion_reward) |> Tez.of_q ~round_up:false)
      total_slashed
    |> List.fold_left Tez.( +! ) Tez.zero
  in
  let account_map =
    add_liquid_rewards reward_to_snitch rewarded_name account_map
  in
  let actual_total_burnt_amount =
    Tez.(total_before_slash -! total_after_slash -! reward_to_snitch)
  in
  (account_map, actual_total_burnt_amount)

(* Given cycle is the cycle for which the rights are computed, usually current +
   consensus rights delay *)
let update_frozen_rights_cycle cycle account_map =
  String.Map.map
    (fun ({frozen_deposits; frozen_rights; _} as acc) ->
      let total_frozen = Frozen_tez.total_current frozen_deposits in
      let frozen_rights = CycleMap.add cycle total_frozen frozen_rights in
      {acc with frozen_rights})
    account_map

let get_balance_from_context ctxt contract =
  let open Lwt_result_syntax in
  let* liquid_b = Context.Contract.balance ctxt contract in
  let* bonds_b = Context.Contract.frozen_bonds ctxt contract in
  let* staked_b = Context.Contract.staked_balance ctxt contract in
  let staked_b =
    Option.value ~default:Tez.zero staked_b |> Partial_tez.of_tez
  in
  let* unstaked_frozen_b =
    Context.Contract.unstaked_frozen_balance ctxt contract
  in
  let unstaked_frozen_b = Option.value ~default:Tez.zero unstaked_frozen_b in
  let* unstaked_finalizable_b =
    Context.Contract.unstaked_finalizable_balance ctxt contract
  in
  let unstaked_finalizable_b =
    Option.value ~default:Tez.zero unstaked_finalizable_b
  in
  let* total_balance = Context.Contract.full_balance ctxt contract in
  let* staking_delegator_numerator_b =
    Context.Contract.staking_numerator ctxt contract
  in
  let*! staking_delegate_denominator_b =
    match (contract : Protocol.Alpha_context.Contract.t) with
    | Implicit pkh ->
        let*! result = Context.Delegate.staking_denominator ctxt pkh in
        Lwt.return
          (match result with
          | Ok v -> v
          | Error _ -> (* Not a delegate *) Z.zero)
    | Originated _ -> Lwt.return Z.zero
  in
  let bd =
    {
      liquid_b;
      bonds_b;
      staked_b;
      unstaked_frozen_b;
      unstaked_finalizable_b;
      staking_delegator_numerator_b;
      staking_delegate_denominator_b;
    }
  in
  return (bd, total_balance)

let assert_balance_check ~loc ctxt account_name account_map =
  let open Lwt_result_syntax in
  match String.Map.find account_name account_map with
  | None -> raise Not_found
  | Some account ->
      let* balance_ctxt, total_balance_ctxt =
        get_balance_from_context ctxt account.contract
      in
      let balance, total_balance =
        balance_and_total_balance_of_account account_name account_map
      in
      let*! r1 = assert_balance_equal ~loc account_name balance_ctxt balance in
      let*! r2 =
        Assert.equal
          ~loc
          Tez.equal
          (Format.asprintf "%s : Total balances do not match" account_name)
          Tez.pp
          total_balance_ctxt
          total_balance
      in
      join_errors r1 r2

let get_launch_cycle ~loc blk =
  let open Lwt_result_syntax in
  let* launch_cycle_opt = Context.get_adaptive_issuance_launch_cycle (B blk) in
  Assert.get_some ~loc launch_cycle_opt

(** AI operations *)

let stake ctxt contract amount =
  Op.transaction
    ctxt
    ~entrypoint:Protocol.Alpha_context.Entrypoint.stake
    ~fee:Tez.zero
    contract
    contract
    amount

let set_delegate_parameters ctxt delegate
    ~parameters:{limit_of_staking_over_baking; edge_of_baking_over_staking} =
  let entrypoint = Protocol.Alpha_context.Entrypoint.set_delegate_parameters in
  let limit_of_staking_over_baking_millionth =
    Q.mul limit_of_staking_over_baking (Q.of_int 1_000_000) |> Q.to_int
  in
  let edge_of_baking_over_staking_billionth =
    Q.mul edge_of_baking_over_staking (Q.of_int 1_000_000_000) |> Q.to_int
  in
  let parameters =
    Protocol.Alpha_context.Script.lazy_expr
      (Expr.from_string
         (Printf.sprintf
            "Pair %d (Pair %d Unit)"
            limit_of_staking_over_baking_millionth
            edge_of_baking_over_staking_billionth))
  in
  Op.transaction
    ctxt
    ~entrypoint
    ~parameters
    ~fee:Tez.zero
    delegate
    delegate
    Tez.zero

let unstake ctxt contract amount =
  Op.transaction
    ctxt
    ~entrypoint:Protocol.Alpha_context.Entrypoint.unstake
    ~fee:Tez.zero
    contract
    contract
    amount

let finalize_unstake ctxt ?(amount = Tez.zero) contract =
  Op.transaction
    ctxt
    ~entrypoint:Protocol.Alpha_context.Entrypoint.finalize_unstake
    ~fee:Tez.zero
    contract
    contract
    amount

let portion_of_rewards_to_liquid_for_cycle ?policy ctxt cycle pkh rewards =
  let open Lwt_result_syntax in
  let* {frozen; weighted_delegated} =
    Context.Delegate.stake_for_cycle ?policy ctxt cycle pkh
  in
  let portion = Tez.(ratio weighted_delegated (frozen +! weighted_delegated)) in
  let to_liquid = Tez.mul_q rewards portion in
  return (Partial_tez.to_tez ~round_up:false to_liquid)
