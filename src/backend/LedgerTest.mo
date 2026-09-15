// ICRC-1/2 ledger unit tests (B1). Exercises the pure apply functions of
// Icrc.mo directly, including the B1 accounting invariant:
//   sum(all balances) == totalSupply   after every operation.

import Icrc "Icrc";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

module {

  func alice() : Icrc.Account { { owner = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"); subaccount = null } };
  func bob() : Icrc.Account { { owner = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"); subaccount = null } };
  func mintAcc() : Icrc.Account { { owner = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai"); subaccount = null } };

  func freshState() : Icrc.State {
    let s = Icrc.init();
    s.mintingAccount := ?mintAcc();
    s;
  };

  // sum over the three accounts used by the suite
  func sumSupply(s : Icrc.State) : Nat {
    Icrc.balanceOf(s, alice()) + Icrc.balanceOf(s, bob()) + Icrc.balanceOf(s, mintAcc());
  };

  func expectOkNat(r : Result.Result<Nat, Any>) : Nat {
    switch (r) {
      case (#ok v) { v };
      case (#err _) { Runtime.trap("expected #ok") };
    };
  };

  public func run() : async () {
    let NOW : Nat64 = 1_700_000_000_000_000_000;

    // --- mint + basic balances ---------------------------------------------
    do {
      let s = freshState();
      assert Icrc.applyMint(s, alice(), 1_000_000) == 1_000_000;
      assert Icrc.balanceOf(s, alice()) == 1_000_000;
      assert s.totalSupply == 1_000_000;
      assert sumSupply(s) == s.totalSupply;
    };

    // --- transfer accounting: fee burned, net moved -------------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = bob(); amount = 100_000; fee = null; memo = null; created_at_time = null }, NOW);
      let moved = expectOkNat(r);
      assert moved == 100_000;
      // alice: 1_000_000 - 100_000 - 10_000 fee
      assert Icrc.balanceOf(s, alice()) == 890_000;
      // bob gets the full amount
      assert Icrc.balanceOf(s, bob()) == 100_000;
      // fee was burned: supply = 1_000_000 - 10_000
      assert s.totalSupply == 990_000;
      assert s.feeCollected == 10_000;
      assert sumSupply(s) == s.totalSupply; // the invariant
    };

    // --- explicit wrong fee rejected with BadFee ----------------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = bob(); amount = 100_000; fee = ?1; memo = null; created_at_time = null }, NOW);
      switch (r) {
        case (#err(#BadFee { expected_fee })) { assert expected_fee == Icrc.FEE };
        case _ { Runtime.trap("expected BadFee") };
      };
    };

    // --- insufficient funds (amount + fee together) --------------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 100_000); // exactly amount, not + fee
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = bob(); amount = 100_000; fee = null; memo = null; created_at_time = null }, NOW);
      switch (r) {
        case (#err(#InsufficientFunds { balance })) { assert balance == 100_000 };
        case _ { Runtime.trap("expected InsufficientFunds") };
      };
      // failed transfer must not touch state
      assert Icrc.balanceOf(s, alice()) == 100_000;
      assert s.totalSupply == 100_000;
    };

    // --- zero amount rejected ------------------------------------------------
    do {
      let s = freshState();
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = bob(); amount = 0; fee = null; memo = null; created_at_time = null }, NOW);
      switch (r) {
        case (#err(#GenericError _)) {};
        case _ { Runtime.trap("expected GenericError on zero amount") };
      };
    };

    // --- CreatedInFuture rejected --------------------------------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = bob(); amount = 1_000; fee = null; memo = null; created_at_time = ?(NOW + 1_000_000) }, NOW);
      switch (r) {
        case (#err(#CreatedInFuture _)) {};
        case _ { Runtime.trap("expected CreatedInFuture") };
      };
    };

    // --- burn: transfer TO the minting account shrinks supply -----------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = mintAcc(); amount = 500_000; fee = null; memo = null; created_at_time = null }, NOW);
      let burned = expectOkNat(r);
      assert burned == 500_000;
      assert s.totalSupply == 1_000_000 - 500_000 - Icrc.FEE;
      assert Icrc.balanceOf(s, mintAcc()) == 0; // minting account always empty
      assert sumSupply(s) == s.totalSupply;
    };

    // --- BadBurn: sub-fee-floor burn rejected ---------------------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);
      let r = Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = mintAcc(); amount = 1; fee = null; memo = null; created_at_time = null }, NOW);
      switch (r) {
        case (#err(#BadBurn { min_burn_amount })) { assert min_burn_amount == Icrc.FEE };
        case _ { Runtime.trap("expected BadBurn") };
      };
    };

    // --- approve -> allowance -> transfer_from -> revoke lifecycle -------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);

      // approve bob as spender of 300_000
      let a = Icrc.applyApprove(s, alice(), { from_subaccount = null; spender = bob(); amount = 300_000; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      assert expectOkNat(a) == 300_000;
      assert Icrc.allowance(s, alice(), bob()) == 300_000;
      assert Icrc.balanceOf(s, alice()) == 1_000_000 - Icrc.FEE; // approval charged the fee
      assert s.feeCollected == Icrc.FEE;

      // bob spends 120_000 of alice's balance
      let tf = Icrc.applyTransferFrom(s, bob(), { spender_subaccount = null; from = alice(); to = bob(); amount = 120_000; fee = null; memo = null; created_at_time = null }, NOW);
      assert expectOkNat(tf) == 120_000;
      assert Icrc.allowance(s, alice(), bob()) == 180_000;
      assert Icrc.balanceOf(s, bob()) == 120_000;
      assert Icrc.balanceOf(s, alice()) == 1_000_000 - Icrc.FEE - 120_000 - Icrc.FEE; // transfer_from fee also charged to from
      assert sumSupply(s) == s.totalSupply;

      // revoke: zero-amount approval clears the allowance
      let rv = Icrc.applyApprove(s, alice(), { from_subaccount = null; spender = bob(); amount = 0; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      assert expectOkNat(rv) == 0;
      assert Icrc.allowance(s, alice(), bob()) == 0;

      // spending after revoke fails with InsufficientAllowance
      let tf2 = Icrc.applyTransferFrom(s, bob(), { spender_subaccount = null; from = alice(); to = bob(); amount = 1; fee = null; memo = null; created_at_time = null }, NOW);
      switch (tf2) {
        case (#err(#InsufficientAllowance { allowance })) { assert allowance == 0 };
        case _ { Runtime.trap("expected InsufficientAllowance after revoke") };
      };
    };

    // --- expected_allowance CAS rejects concurrent changes ---------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 1_000_000);
      ignore Icrc.applyApprove(s, alice(), { from_subaccount = null; spender = bob(); amount = 500; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      // CAS with the wrong current value fails
      let cas = Icrc.applyApprove(s, alice(), { from_subaccount = null; spender = bob(); amount = 900; expected_allowance = ?499; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      switch (cas) {
        case (#err(#AllowanceChanged { current_allowance })) { assert current_allowance == 500 };
        case _ { Runtime.trap("expected AllowanceChanged") };
      };
      // CAS with the right value succeeds
      let cas2 = Icrc.applyApprove(s, alice(), { from_subaccount = null; spender = bob(); amount = 900; expected_allowance = ?500; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      assert expectOkNat(cas2) == 900;
      assert Icrc.allowance(s, alice(), bob()) == 900;
    };

    // --- approval on empty balance rejects (fee unpayable) ----------------------
    do {
      let s = freshState();
      let a = Icrc.applyApprove(s, alice(), { from_subaccount = null; spender = bob(); amount = 100; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      switch (a) {
        // ApproveError has no InsufficientFunds (canonical ledgers trap); the
        // B1 module surfaces it as GenericError — see Icrc.mo.
        case (#err(#GenericError _)) {};
        case _ { Runtime.trap("expected GenericError for approve fee") };
      };
    };

    // --- mint/supply conservation across a mixed flow ---------------------------
    do {
      let s = freshState();
      ignore Icrc.applyMint(s, alice(), 2_000_000);
      ignore Icrc.applyTransfer(s, alice(), { from_subaccount = null; to = bob(); amount = 400_000; fee = null; memo = null; created_at_time = null }, NOW);
      ignore Icrc.applyApprove(s, bob(), { from_subaccount = null; spender = alice(); amount = 50_000; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null }, NOW);
      ignore Icrc.applyTransferFrom(s, alice(), { spender_subaccount = null; from = bob(); to = alice(); amount = 20_000; fee = null; memo = null; created_at_time = null }, NOW);
      ignore Icrc.applyTransfer(s, bob(), { from_subaccount = null; to = mintAcc(); amount = 300_000; fee = null; memo = null; created_at_time = null }, NOW); // burn
      // supply math: 2_000_000 minted - 4 fees (2 transfers + approve + transfer_from) - 300_000 burned
      assert s.totalSupply == 2_000_000 - 4 * Icrc.FEE - 300_000;
      assert sumSupply(s) == s.totalSupply;
    };

    // --- subaccount identity: same owner, different subaccount = different acct --
    do {
      let s = freshState();
      let aliceSub : Icrc.Account = { owner = alice().owner; subaccount = ?"\01" };
      ignore Icrc.applyMint(s, alice(), 500_000);
      assert Icrc.balanceOf(s, aliceSub) == 0; // not the same balance slot
      ignore Icrc.applyMint(s, aliceSub, 7);
      assert Icrc.balanceOf(s, aliceSub) == 7;
      assert Icrc.balanceOf(s, alice()) == 500_000;
    };

    Debug.print("Ledger tests passed");
  };
};
