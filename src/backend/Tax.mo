// Tax parity math for CKLUNC — exact integer arithmetic, floored toward the user.
// Mirrors LUNC's burn tax: rate is a 10^-18 fixed-point Dec string on the chain
// ("0.015000000000000000"); amounts are 6-decimal micro-units (uluna-style).
import Nat "mo:core/Nat";
import Text "mo:core/Text";

module Tax {

  public type Params = {
    burnTaxRate : Text; // decimal string, 10^-18 fixed point
    epoch : Nat;
    fetchedAtNs : Int;
  };

  // Parse a Cosmos SDK Dec string ("0.015", "0.015000000000000000", "1") into a
  // 10^18-scaled Nat. Malformed input yields 0 (fail-safe direction; params are
  // sanity-bounded by the caller before use).
  public func decToScaled18(s : Text) : Nat {
    let chars = Text.toArray(s);
    let n = chars.size();
    var intDigits : Text = "0";
    var fracDigits : Text = "";
    var seenDot : Bool = false;
    var bad : Bool = n == 0;
    var i : Nat = 0;
    while (i < n) {
      let c = chars[i];
      if (c == '.') {
        if (seenDot) { bad := true };
        seenDot := true;
      } else if (c >= '0' and c <= '9') {
        if (seenDot) {
          if (fracDigits.size() < 18) {
            fracDigits := fracDigits # Text.fromChar(c);
          };
        } else {
          if (intDigits == "0") {
            intDigits := Text.fromChar(c); // drop leading zeros
          } else {
            intDigits := intDigits # Text.fromChar(c);
          };
        };
      } else {
        bad := true;
      };
      i += 1;
    };
    if (bad) { return 0 };
    // pad fraction to exactly 18 digits
    while (fracDigits.size() < 18) {
      fracDigits := fracDigits # "0";
    };
    switch (Nat.fromText(intDigits # fracDigits)) {
      case (?v) { v };
      case null { 0 };
    };
  };

  // tax = amount × rate, floored (never tax more than the rate says).
  public func taxOn(amount : Nat, rateScaled18 : Nat) : Nat {
    amount * rateScaled18 / 1_000_000_000_000_000_000;
  };

  // The taxed-transfer split: (net, tax) with net + tax = amount exactly.
  public func split(amount : Nat, rateScaled18 : Nat) : (Nat, Nat) {
    let tax = taxOn(amount, rateScaled18);
    (amount - tax, tax);
  };

  // --- rate policy ----------------------------------------------------------
  // Parity by default; a governed override applies only when it is strictly
  // below the mirrored rate (the twin must never cost more than the chain it
  // mirrors) and params are fresh. Everything else falls back to parity —
  // never to 0 by accident. Pure: the actor owns freshness and refusal.
  public type RateMode = { #parity; #override };

  public func effectiveRate(mirrored : Nat, overrideRate : ?Nat, paramsFresh : Bool) : (Nat, RateMode) {
    switch (overrideRate) {
      case (?o) {
        if (paramsFresh and o < mirrored) {
          (o, #override);
        } else {
          (mirrored, #parity);
        };
      };
      case null { (mirrored, #parity) };
    };
  };

  // Wire-format provenance: "parity" | "override" ("refused" is actor-level).
  public func modeText(m : RateMode) : Text {
    switch (m) {
      case (#parity) { "parity" };
      case (#override) { "override" };
    };
  };

  // Sanity bounds accepted from the params feed: 0 <= rate <= 5%.
  // (Historical LUNC burn rates: 0.5% → 1.5%; 5% leaves headroom while still
  // rejecting garbage. The bound REJECTING the live rate would be the bug.)
  public let MAX_RATE_SCALED18 : Nat = 50_000_000_000_000_000; // 0.05 × 10^18

  public func rateIsSane(rateScaled18 : Nat) : Bool {
    rateScaled18 <= MAX_RATE_SCALED18;
  };
};
