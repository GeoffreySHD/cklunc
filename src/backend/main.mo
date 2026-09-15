// CKLUNC minter — v1 core: dynamic tax parity + burn ledger + conservation
// invariants. The bridge (deposit detection, threshold-ECDSA custody) lands in
// later phases (B3/B2b); this module is the interface everything else codes
// against, with the tax/burn accounting complete and testable today.
//
// Time policy: every timestamp is canister-consensus Time.now() taken at the
// moment of the state change. Callers NEVER supply clocks — otherwise a caller
// could present a fresh `nowNs` against params that were fetched weeks ago.
// Rate policy: parity with the mirrored LUNC rate is the default; a
// controller-governed override may only LOWER it (the twin must never cost
// more than the chain it mirrors). Every taxed response carries `rate_mode`
// provenance: "parity" | "override" | "refused" (stale params = refused).
import Tax "Tax";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";

persistent actor CKLunc {

  transient let DECIMALS : Nat = 6; // mirrors LUNC, not ICP's 8

  type Entry = (Nat, Nat, Nat, Text); // (burnEpochId, ckluncBurned, underlyingPending, memo)

  // --- stable state ---------------------------------------------------------
  var paramsEpoch : Nat = 0;
  var paramsRateScaled18 : Nat = 0; // parsed via Tax.decToScaled18
  var paramsFetchedAtNs : Int = 0;
  var paramsMaxAgeNs : Int = 86_400_000_000_000; // 24h freshness bound (fail-closed after)
  var overrideRateScaled18 : ?Nat = null; // governed; must stay strictly below the mirrored rate

  var totalTaxedVolume : Nat = 0;
  var totalTaxBurned : Nat = 0; // CKLUNC burned via taxed_transfer
  var underlyingBurnedSettled : Nat = 0; // LUNC burns confirmed settled on Terra Classic
  var nextBurnEpoch : Nat = 1;

  // Burn ledger in a mutable backing array with geometric growth.
  // recordBurn is O(1) amortized; markSettled is a single in-place O(n) pass.
  // Replaced by stable structures at B4.
  var ledgerData : [var Entry] = VarArray.repeat<Entry>((0, 0, 0, ""), 16);
  var ledgerLen : Nat = 0;

  var openEpochClosed : Bool = false;

  func growLedger(min : Nat) {
    if (min <= ledgerData.size()) { return };
    var cap = ledgerData.size() * 2;
    while (cap < min) { cap *= 2 };
    let fresh = VarArray.repeat<Entry>((0, 0, 0, ""), cap);
    var i = 0;
    while (i < ledgerLen) { fresh[i] := ledgerData[i]; i += 1 };
    ledgerData := fresh;
  };

  func pushEntry(e : Entry) {
    growLedger(ledgerLen + 1);
    ledgerData[ledgerLen] := e;
    ledgerLen += 1;
  };

  func paramsFresh(nowNs : Int) : Bool {
    paramsEpoch > 0 and (nowNs - paramsFetchedAtNs) <= paramsMaxAgeNs;
  };

  // --- admin gate -----------------------------------------------------------
  // Controller-only for state-changing admin calls. Pre-B2b that is the
  // deployer; after decentralization the controllers ARE the governing
  // canisters, so the gate remains correct without redeploying.
  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("controller only") };
  };

  // --- params feed ----------------------------------------------------------
  /// Called by the params-feed (B3.5: N-LCD majority outcalls land there; v1
  /// accepts the deployer/controller feed). Rate is a Cosmos Dec string.
  /// The fetch timestamp is consensus time NOW, not a caller-supplied value.
  public shared ({ caller }) func setTaxParams(rateDec : Text) : async { accepted : Bool; reason : ?Text } {
    requireController(caller);
    let r = Tax.decToScaled18(rateDec);
    if (not Tax.rateIsSane(r)) {
      return { accepted = false; reason = ?"rate outside sanity bounds" };
    };
    paramsRateScaled18 := r;
    paramsEpoch += 1;
    paramsFetchedAtNs := Time.now();
    // An existing override is left in place: if the new mirrored rate moved
    // below it, the policy clamps to parity automatically — no admin action.
    { accepted = true; reason = null };
  };

  /// Governed rate override. Only strictly-below-mirrored, sane rates are
  /// accepted (0 allowed for liquidity-routing regimes). If the mirrored rate
  /// later drops below the override, parity wins automatically.
  public shared ({ caller }) func setRateOverride(rateDec : Text) : async { accepted : Bool; reason : ?Text } {
    requireController(caller);
    if (paramsEpoch == 0) {
      return { accepted = false; reason = ?"no mirrored params yet" };
    };
    let r = Tax.decToScaled18(rateDec);
    if (not Tax.rateIsSane(r)) {
      return { accepted = false; reason = ?"rate outside sanity bounds" };
    };
    if (r >= paramsRateScaled18) {
      return { accepted = false; reason = ?"override must be strictly below the mirrored rate" };
    };
    overrideRateScaled18 := ?r;
    { accepted = true; reason = null };
  };

  /// Return to full parity.
  public shared ({ caller }) func clearRateOverride() : async { cleared : Bool } {
    requireController(caller);
    overrideRateScaled18 := null;
    { cleared = true };
  };

  /// Freshness bound knob: the DAO trades feed cadence against staleness.
  /// Bounds 1h..7d keep the fail-closed guarantee meaningful either way.
  public shared ({ caller }) func setParamsMaxAgeNs(ns : Int) : async { accepted : Bool; reason : ?Text } {
    requireController(caller);
    if (ns < 3_600_000_000_000) {
      return { accepted = false; reason = ?"below minimum freshness bound (1h)" };
    };
    if (ns > 7 * 86_400_000_000_000) {
      return { accepted = false; reason = ?"above maximum freshness bound (7d)" };
    };
    paramsMaxAgeNs := ns;
    { accepted = true; reason = null };
  };

  public query func tax_params() : async { burnTaxRate : Text; epoch : Nat; override_rate : ?Text; rate_mode : Text } {
    let mode = if (not paramsFresh(Time.now())) {
      "refused";
    } else {
      let (_, m) = Tax.effectiveRate(paramsRateScaled18, overrideRateScaled18, true);
      Tax.modeText(m);
    };
    {
      burnTaxRate = formatDec18(paramsRateScaled18);
      epoch = paramsEpoch;
      override_rate = switch (overrideRateScaled18) { case (?o) { ?formatDec18(o) }; case null { null } };
      rate_mode = mode;
    };
  };

  /// Fail-closed gate: taxed operations refuse when params are stale/absent.
  public query func tax_params_fresh() : async Bool {
    paramsFresh(Time.now());
  };

  // --- taxed transfer (the core primitive) ----------------------------------
  // Current effective rate + provenance, or null when params are stale
  // (fail-closed: callers must refuse to execute).
  func effectiveRateNow() : ?(Nat, Text) {
    if (not paramsFresh(Time.now())) { return null };
    let (r, m) = Tax.effectiveRate(paramsRateScaled18, overrideRateScaled18, true);
    ?(r, Tax.modeText(m));
  };

  /// Preview the taxed split. Never traps; returns epoch 0 and rate_mode
  /// "refused" when params are not fresh.
  public func taxed_transfer_preview(amount : Nat) : async { net : Nat; tax : Nat; epoch : Nat; rate_mode : Text } {
    switch (effectiveRateNow()) {
      case null { return { net = amount; tax = 0; epoch = 0; rate_mode = "refused" } };
      case (?(rate, mode)) {
        let (net, tax) = Tax.split(amount, rate);
        { net; tax; epoch = paramsEpoch; rate_mode = mode };
      };
    };
  };

  /// Execute a taxed burn: records `tax` into the burn ledger (CKLUNC burned),
  /// with net + tax = amount conserved exactly. The ICRC-2 pull and ledger
  /// credit wire in at B2; the burn accounting is production-complete now.
  public func taxed_transfer(amount : Nat) : async { net : Nat; tax : Nat; burnEpoch : Nat; rate_mode : Text } {
    if (amount == 0) {
      // zero-value burns would only add noise entries to the settlement ledger
      return { net = 0; tax = 0; burnEpoch = 0; rate_mode = "refused" };
    };
    switch (effectiveRateNow()) {
      case null {
        // fail-closed: no execution on stale params
        return { net = amount; tax = 0; burnEpoch = 0; rate_mode = "refused" };
      };
      case (?(rate, mode)) {
        let (net, tax) = Tax.split(amount, rate);
        let epoch = recordBurn(tax);
        totalTaxedVolume += amount;
        totalTaxBurned += tax;
        { net; tax; burnEpoch = epoch; rate_mode = mode };
      };
    };
  };

  // --- burn ledger ----------------------------------------------------------
  /// Record a CKLUNC burn into the open settlement epoch (create one if none).
  /// O(1) amortized: appending to the open epoch updates the tail in place.
  func recordBurn(ckluncBurned : Nat) : Nat {
    let n = ledgerLen;
    if (n == 0 or openEpochClosed) {
      let id = nextBurnEpoch;
      nextBurnEpoch += 1;
      let memo = "icp-burn-epoch-" # Nat.toText(id);
      pushEntry((id, ckluncBurned, ckluncBurned, memo));
      openEpochClosed := false;
      return id;
    };
    // the open epoch is the LAST entry (chronological order)
    let (id, ck, und, memo) = ledgerData[n - 1]; // n >= 1 by the branch above
    ledgerData[n - 1] := (id, ck + ckluncBurned, und + ckluncBurned, memo);
    id;
  };

  /// B2b hook: custody broadcast confirmed for all pending underlying burns.
  /// Links the LUNC settlement tx into every pending epoch's memo and zeroes
  /// pending. Single in-place O(n) pass — no ledger rebuild.
  public shared ({ caller }) func markSettled(luncTxId : Text) : async { settled : Nat } {
    requireController(caller);
    var settledTotal : Nat = 0;
    var i = 0;
    while (i < ledgerLen) {
      let (id, ck, und, memo) = ledgerData[i];
      if (und > 0) {
        underlyingBurnedSettled += und;
        settledTotal += und;
        ledgerData[i] := (id, ck, 0, memo # "|lunc_tx:" # luncTxId);
      };
      i += 1;
    };
    openEpochClosed := true;
    { settled = settledTotal };
  };

  public query func burn_ledger() : async [Entry] {
    // immutable snapshot copy — the backing array is never handed out
    Array.tabulate<Entry>(ledgerLen, func(i : Nat) : Entry { ledgerData[i] });
  };

  public query func tax_stats() : async {
    totalTaxedVolume : Nat;
    totalTaxBurned : Nat;
    underlyingBurnedSettled : Nat;
    decimals : Nat;
  } {
    {
      totalTaxedVolume;
      totalTaxBurned;
      underlyingBurnedSettled;
      decimals = DECIMALS;
    };
  };

  // --- formatting helpers ---------------------------------------------------
  func formatDec18(v : Nat) : Text {
    if (v == 0) { return "0" };
    let s = Nat.toText(v);
    if (s.size() <= 18) {
      var p = s;
      while (p.size() < 18) { p := "0" # p };
      return "0." # p;
    };
    let cut = s.size() - 18;
    trimEnd(Text.concat(Text.fromArray(Array.tabulate<Char>(cut, func(i : Nat) : Char { Text.toArray(s)[i] })), "." # tail18(s)));
  };

  func tail18(s : Text) : Text {
    let a = Text.toArray(s);
    let start = a.size() - 18;
    Text.fromArray(Array.tabulate<Char>(18, func(i : Nat) : Char { a[start + i] }));
  };

  func trimEnd(t : Text) : Text {
    // strip trailing '0's but keep at least one fractional digit
    let a = Text.toArray(t);
    var end = a.size();
    while (end > 1 and a[end - 1] == '0' and a[end - 2] != '.') {
      end -= 1;
    };
    Text.fromArray(Array.tabulate<Char>(end, func(i : Nat) : Char { a[i] }));
  };
};
