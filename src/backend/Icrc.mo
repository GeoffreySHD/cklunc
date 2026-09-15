// Inline ICRC-1/ICRC-2 token logic for CKLUNC (B1 PoC).
//
// Why inline instead of a mops library: `dfinity/icrc1-mo` (the canonical
// Motoko ICRC ledger) was 404-unreachable during this build and the mops
// registry is DNS-blocked on the dev network, so the dependency could not be
// vendored verifiably. This module implements the standard's wire surface,
// validated against the official dfinity/ICRC-1 candid files (ICRC-1.did,
// ICRC-2.did): icrc1_* endpoints + icrc2_approve/transfer_from/allowance,
// flat-fee model, standard error variants.
//
// B6 (NNS/SNS adoption) note: at adoption time the ledger is expected to
// migrate to the official ic-cdk Rust ICRC-1 ledger suite (or a revived
// icrc1-mo). Balances survive via ICRC-3 `init_state` export — trivial while
// total supply is still 0 pre-launch. Adoption itself is a controller change;
// same canister IDs, no re-mint. Documented in the README roadmap.
//
// B1 accounting model (a documented deviation from the canonical ledger):
// fees and taxes are BURNED outright rather than parked in the minting
// account, so the exact invariant  sum(all balances) = totalSupply  holds at
// every step (asserted in LedgerTest.mo). The canonical fee-to-minting-account
// model is adopted at the B6 migration alongside the Rust ledger.

import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";

module Icrc {

  public type Account = { owner : Principal; subaccount : ?Blob };
  public type TransferArgs = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #TemporarilyUnavailable;
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
  };
  public type ApproveArgs = {
    from_subaccount : ?Blob;
    spender : Account;
    amount : Nat;
    expected_allowance : ?Nat;
    expires_at : ?Nat64;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type ApproveError = {
    #BadFee : { expected_fee : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #TemporarilyUnavailable;
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
  };
  public type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #TemporarilyUnavailable;
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
  };
  public type SupportedStandard = { name : Text; url : Text };

  // B1 PoC flat fee (10k base units = 0.01 CKLUNC at decimals 6). The B3.5
  // params feed converts this into the mirrored dynamic rate (policy already
  // implemented in Tax.mo / the minter).
  public let FEE : Nat = 10_000;

  // Canonical account key: owner principal + lowercase-hex subaccount.
  // Accounts are stored exactly as provided; equality is key-based.
  public func accountKey(a : Account) : Text {
    Principal.toText(a.owner) # "." # (switch (a.subaccount) {
      case null { "" };
      case (?s) { hex(Blob.toArray(s)) };
    });
  };

  private func hex(bytes : [Nat8]) : Text {
    let digits = "0123456789abcdef";
    var t = "";
    for (b in bytes.values()) {
      let hi : Nat8 = b / 16;
      let lo : Nat8 = b % 16;
      t := t # Text.fromChar(charAt(digits, Nat8.toNat(hi)))
           # Text.fromChar(charAt(digits, Nat8.toNat(lo)));
    };
    t;
  };

  private func charAt(s : Text, i : Nat) : Char {
    Text.toArray(s)[i];
  };

  public type State = {
    var mintingAccount : ?Account;
    var totalSupply : Nat;
    var balances : Map.Map<Text, Nat>;
    var allowances : Map.Map<Text, Nat>;
    var feeCollected : Nat;
  };

  public func init() : State {
    {
      var mintingAccount = null;
      var totalSupply = 0;
      var balances = Map.empty<Text, Nat>();
      var allowances = Map.empty<Text, Nat>();
      var feeCollected = 0;
    };
  };

  public func allowanceKey(owner : Account, spender : Account) : Text {
    accountKey(owner) # ">" # accountKey(spender);
  };

  public func balanceOf(s : State, a : Account) : Nat {
    switch (Map.get<Text, Nat>(s.balances, Text.compare, accountKey(a))) {
      case (?b) { b };
      case null { 0 };
    };
  };

  public func setBalance(s : State, a : Account, v : Nat) {
    Map.add<Text, Nat>(s.balances, Text.compare, accountKey(a), v);
  };

  public func accountIsMinting(s : State, a : Account) : Bool {
    switch (s.mintingAccount) {
      case null { false };
      case (?m) { accountKey(m) == accountKey(a) };
    };
  };

  // ---- pure apply functions (unit-tested in LedgerTest.mo) -----------------

  /// Standard transfer. Deducts amount + fee from `from`; credits `to` with
  /// amount. Fees are burned outright (B1 PoC model — see module header).
  /// Transfer TO the minting account is a burn (supply shrinks by amount).
  /// No state change on error.
  public func applyTransfer(s : State, from : Account, args : TransferArgs, now : Nat64) : Result.Result<Nat, TransferError> {
    if (args.amount == 0) {
      return #err(#GenericError { error_code = 1; message = "amount must be non-zero" });
    };
    let fee = switch (args.fee) {
      case (?f) { if (f != FEE) { return #err(#BadFee { expected_fee = FEE }) } else { FEE } };
      case null { FEE };
    };
    let bal = balanceOf(s, from);
    if (bal < args.amount + fee) {
      return #err(#InsufficientFunds { balance = bal });
    };
    switch (args.created_at_time) {
      case (?t) { if (t > now) { return #err(#CreatedInFuture { ledger_time = now }) } };
      case null {};
    };
    let burn = accountIsMinting(s, args.to);
    if (burn and args.amount < FEE) {
      return #err(#BadBurn { min_burn_amount = FEE });
    };
    setBalance(s, from, bal - args.amount - fee);
    if (burn) {
      // tokens sent to the minting account are destroyed, never credited
      s.totalSupply -= args.amount;
    } else {
      setBalance(s, args.to, balanceOf(s, args.to) + args.amount);
    };
    if (fee > 0) {
      // B1 PoC model: fees are burned outright; the minting account is a pure
      // burn address. Canonical fee-to-minting lands at the B6 migration.
      s.totalSupply -= fee;
      s.feeCollected += fee;
    };
    #ok(args.amount);
  };

  /// Approval (ICRC-2). Zero amount revokes. `expected_allowance` acts as CAS.
  public func applyApprove(s : State, from : Account, args : ApproveArgs, now : Nat64) : Result.Result<Nat, ApproveError> {
    let fee = switch (args.fee) {
      case (?f) { if (f != FEE) { return #err(#BadFee { expected_fee = FEE }) } else { FEE } };
      case null { FEE };
    };
    let bal = balanceOf(s, from);
    if (bal < fee) {
      // ICRC-2 canonical ledgers trap here (ApproveError has no
      // InsufficientFunds). We return GenericError instead: identical UX at
      // the HTTP layer (a reject), but observable and testable in the B1 suite.
      return #err(#GenericError { error_code = 2; message = "insufficient funds to cover the approval fee" });
    };
    switch (args.created_at_time) {
      case (?t) { if (t > now) { return #err(#CreatedInFuture { ledger_time = now }) } };
      case null {};
    };
    switch (args.expected_allowance) {
      case (?exp) {
        let cur = allowance(s, from, args.spender);
        if (cur != exp) { return #err(#AllowanceChanged { current_allowance = cur }) };
      };
      case null {};
    };
    let key = allowanceKey(from, args.spender);
    if (args.amount == 0) {
      ignore Map.delete<Text, Nat>(s.allowances, Text.compare, key);
    } else {
      Map.add<Text, Nat>(s.allowances, Text.compare, key, args.amount);
    };
    setBalance(s, from, bal - fee);
    if (fee > 0) {
      s.totalSupply -= fee;
      s.feeCollected += fee;
    };
    #ok(args.amount);
  };

  public func allowance(s : State, owner : Account, spender : Account) : Nat {
    switch (Map.get<Text, Nat>(s.allowances, Text.compare, allowanceKey(owner, spender))) {
      case (?a) { a };
      case null { 0 };
    };
  };

  /// transfer_from (ICRC-2). Spender identity is passed explicitly by the
  /// endpoint (caller principal + caller-supplied subaccount). Fee is charged
  /// to the FROM balance. Allowance is decremented by amount.
  public func applyTransferFrom(s : State, spender : Account, args : TransferFromArgs, now : Nat64) : Result.Result<Nat, TransferFromError> {
    let fee = switch (args.fee) {
      case (?f) { if (f != FEE) { return #err(#BadFee { expected_fee = FEE }) } else { FEE } };
      case null { FEE };
    };
    let bal = balanceOf(s, args.from);
    if (bal < args.amount + fee) {
      return #err(#InsufficientFunds { balance = bal });
    };
    let allow = allowance(s, args.from, spender);
    if (allow < args.amount) {
      return #err(#InsufficientAllowance { allowance = allow });
    };
    switch (args.created_at_time) {
      case (?t) { if (t > now) { return #err(#CreatedInFuture { ledger_time = now }) } };
      case null {};
    };
    let burn = accountIsMinting(s, args.to);
    if (burn and args.amount < FEE) {
      return #err(#BadBurn { min_burn_amount = FEE });
    };
    setBalance(s, args.from, bal - args.amount - fee);
    if (burn) {
      s.totalSupply -= args.amount;
    } else {
      setBalance(s, args.to, balanceOf(s, args.to) + args.amount);
    };
    if (fee > 0) {
      s.totalSupply -= fee;
      s.feeCollected += fee;
    };
    Map.add<Text, Nat>(s.allowances, Text.compare, allowanceKey(args.from, spender), allow - args.amount);
    #ok(args.amount);
  };

  /// Minter-privileged mint (B2a bridge entry; gated by the actor's
  /// controller check before calling this).
  public func applyMint(s : State, to : Account, amount : Nat) : Nat {
    setBalance(s, to, balanceOf(s, to) + amount);
    s.totalSupply += amount;
    amount;
  };
};
