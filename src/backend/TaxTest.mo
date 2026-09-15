// Tax parity unit tests (mops test runner: 'lunc' runner name is 'main').
import Tax "Tax";
import Debug "mo:core/Debug";

module {
  public func run() : async () {
    // dec parsing: the live chain format
    let r1 = Tax.decToScaled18("0.015000000000000000");
    assert r1 == 15_000_000_000_000_000;
    let r2 = Tax.decToScaled18("0.015");
    assert r2 == 15_000_000_000_000_000;
    let r3 = Tax.decToScaled18("1");
    assert r3 == 1_000_000_000_000_000_000;
    let r4 = Tax.decToScaled18("0.5");
    assert r4 == 500_000_000_000_000_000;

    // tax math: 1.5% of 1_000_000 (1 LUNC) = 15_000
    let (net, tax) = Tax.split(1_000_000, r1);
    assert net == 985_000 and tax == 15_000;
    assert net + tax == 1_000_000; // conservation

    // tiny amounts floor to zero tax (never negative, never trap)
    let (n2, t2) = Tax.split(1, r1);
    assert t2 == 0 and n2 == 1;

    // large amounts: conservation holds and BigInt-like Nat has no overflow
    let big : Nat = 6_449_718_448_764_162_595 * 1_000_000; // >2^63
    let (n3, t3) = Tax.split(big, r1);
    assert n3 + t3 == big;
    assert t3 == big * 15_000_000_000_000_000 / 1_000_000_000_000_000_000;

    // sanity bounds: the live 0.015 rate is accepted; 5% is the max
    assert Tax.rateIsSane(15_000_000_000_000_000);
    assert Tax.rateIsSane(Tax.MAX_RATE_SCALED18);
    assert not Tax.rateIsSane(Tax.MAX_RATE_SCALED18 + 1);

    // rate policy: parity is the default and the fallback
    let (p1, m1) = Tax.effectiveRate(r1, null, true);
    assert p1 == r1 and m1 == #parity;
    // stale params force parity even with a valid override
    let (p2, m2) = Tax.effectiveRate(r1, ?0, false);
    assert p2 == r1 and m2 == #parity;
    // valid lower override applies, including 0% for routing legs
    let (o1, m3) = Tax.effectiveRate(r1, ?10_000_000_000_000_000, true);
    assert o1 == 10_000_000_000_000_000 and m3 == #override;
    let (o2, m4) = Tax.effectiveRate(r1, ?0, true);
    assert o2 == 0 and m4 == #override;
    // override ≥ mirrored never applies (boundary rejects it upstream)
    let (p3, m5) = Tax.effectiveRate(r1, ?r1, true);
    assert p3 == r1 and m5 == #parity;
    let (p4, m6) = Tax.effectiveRate(r1, ?(r1 + 1), true);
    assert p4 == r1 and m6 == #parity;
    // a mirrored-rate INCREASE flows through parity untouched
    let r_hi = 20_000_000_000_000_000; // 2%
    let (p5, m7) = Tax.effectiveRate(r_hi, ?10_000_000_000_000_000, true);
    assert p5 == 10_000_000_000_000_000 and m7 == #override;
    // provenance wire format
    assert Tax.modeText(#parity) == "parity";
    assert Tax.modeText(#override) == "override";

    Debug.print("Tax tests passed");
  };
};
