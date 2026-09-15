# ckLUNC — Terra Classic governance proposal (DRAFT SKELETON)

> **Status: draft — do not post yet.** Scope is locked by our own honesty rules:
> this proposal asks for **roadmap funding (B1→B2b)** with **B0 as proof of
> execution**. It never claims ckLUNC is live, audited, or deployable on mainnet.
> Placeholders marked `[TBD]` must be filled with verified data before posting.

**Suggested on-chain title:**
*ckLUNC: fund the ICP chain-key twin (B1→B2b) — additive LUNC utility, locked supply, dual-chain burns*

## Abstract

ckLUNC is an ICRC-1/ICRC-2 twin of LUNC on the Internet Computer, backed 1:1 by
LUNC held in minter custody, with **burn-tax parity**: every taxed transfer
burns CKLUNC on ICP *and* the equal amount of underlying LUNC on Terra Classic.
We request milestone-based funding for phases B1–B2b (ICRC ledger, bridge
custody, deposit detection, threshold-ECDSA chain-key custody) plus an external
security review. Phase B0 — the tax-parity core, its test suite, and public CI —
is complete and published as proof of execution.

## 1. Motivation — what Terra Classic gets out of it

### 1.1 Add-on utility, not competition

Terra Classic settles value; the Internet Computer executes logic at web speed
with consensus timestamps, canister hosting, and an agent economy Terra Classic
chain throughput cannot host. ckLUNC carries LUNC *into* that execution lane.
Nothing on Terra Classic changes: no fork, no module, no new token issuance.
ckLUNC is purely additive — a second place where LUNC can be used, from which
value flows back as burns.

### 1.2 Supply: locked while bridged, burned as it is used

Two distinct mechanisms, stated separately so nobody conflates them:

- **Locked, reversibly.** LUNC bridged into ckLUNC sits in minter custody —
  out of circulating supply, out of CEX float, and out of circulation for as
  long as it stays bridged. (Custody funds are never staked or delegated —
  they sit liquid, backing the twin 1:1.) Bridging back re-enters supply:
  this is *supply pressure*, not supply destruction.
- **Burned, permanently.** Every taxed ckLUNC transfer burns the tax on ICP
  *and* the equal LUNC on Terra Classic (settlement to a canonical dead
  address, batched per burn epoch, txids public in the burn ledger). ICP-side
  usage volume becomes a **new, non-inflationary burn engine** aligned with
  this community's core supply-reduction goal.

### 1.3 The two lock-up economies (and a correction we owe you)

ICP's growth engine is lock-up: the NNS stakes **ICP** (not LUNC) in neurons
with dissolve delays, and SNS DAOs lock value the same way — the ecosystem is
economically *designed around* locking. Bridging LUNC into ICP plugs idle LUNC
into an economy that rewards locking, and future ckLUNC-side primitives
(governance of the minter via SNS, LP programs on ICP DEXs) would lock CKLUNC
supply further — each locked CKLUNC is LUNC locked in custody. Terra Classic's
own staking is untouched: **ckLUNC targets the LUNC that sits idle** (in
wallets and on exchanges — `[TBD: verify current % staked vs idle before
posting]`), not the staked portion, so it does not cannibalize LUNC
governance participation.

### 1.4 Why tax parity matters to *this* community

A tax-free twin would leak burns away from LUNC. ckLUNC mirrors LUNC's burn-tax
rate live (fail-closed on staleness), and its governance can only set the ICP
rate *strictly below* the mirrored rate — never above. Every ICP-side leg pays
the same burn LUNC legs pay, and that burn lands on Terra Classic.

## 2. Specification (short form)

- ICRC-1/ICRC-2 token, **decimals 6** (mirrors LUNC, not ICP's 8).
- Backing invariant: `minter-held LUNC − (settled + pending underlying burns) ≥ CKLUNC supply`.
- Tax parity: Cosmos Dec (10⁻¹⁸) rate mirrored via an N-LCD majority feed
  (B3.5); stale params freeze taxed operations (`rate_mode: "refused"`).
- Burn ledger: public, per-epoch, LUNC settlement txids attached — anyone can
  reconcile ICP burns against Terra Classic burns.
- ckLUNC is a **unit** twin of LUNC: its value is LUNC's value. No peg claims,
  no stablecoin language, no yield promises — by design and by policy.

## 3. What exists today (proof of execution — B0)

- Tax-parity core: exact integer Dec math, floored tax, `net + tax = amount`
  conservation on arbitrarily large amounts; sanity bounds; rate-override
  policy (lower-only, fail-closed).
- Minter core skeleton: controller-gated params feed, taxed transfer +
  preview with provenance, burn-epoch ledger, settlement hook, stats.
- Test suite green in CI (public); all code MIT, published at
  `github.com/Semence2Porc/cklunc`.

## 4. What we ask funding for (B1→B2b)

| Phase | Deliverable | Acceptance criteria |
|---|---|---|
| B1 | ICRC-1/2 ledger (decimals 6, minter-separated mint/burn) | ICRC-1 compliance checks pass; public testnet deploy |
| B2a | Dev-custodial bridge + ICRC-2 pull wiring | End-to-end testnet bridge; idempotent mint under replay |
| B3 | Deposit detection (LCD outcalls) + circuit breaker | Duplicate-deposit tests; breaker demo on stale feed |
| B3.5 | N-LCD majority tax-params feed | `[TBD: N]`-of-`[TBD]` majority, bounds enforced, fail-closed verified |
| B4 | Accounting invariant + stable structures | Property tests: backing invariant holds under randomized flows |
| B2b | Threshold-ECDSA chain-key custody (coinType 330) | Testnet custody round-trip; **external security review** (funded milestone) |

**Budget: `[TBD]` LUNC** from the community pool, released per milestone with
public acceptance evidence. Alternative if the community prefers: a zero-budget
endorsement proposal now, funding proposal after B1 ships.

## 5. What we explicitly do NOT claim

- **No mainnet custody today.** The repo is testnet-only by design.
- **Settlement is trust-on-controller until B2b/B3.5.** `markSettled` currently
  accepts the controller's assertion that a LUNC burn tx exists; on-chain
  verification lands with B3.5, decentralized custody with B2b. Disclosed now,
  not discovered later.
- **Not audited.** The external review is a funded milestone, not a given.
- **Locked ≠ burned** (see §1.2). We will never market the lock as a burn.
- No yield, no peg, no "stablecoin" wording.

## 6. Chain asks beyond funding (separate proposal, later)

The bridge's LUNC legs are plain `MsgSends` and are currently taxed at 1.5%
both ways — double-charging every bridged LUNC against the invariant above.
The chain has already ruled this way once for contracts: the v4 ante code
(`custom/auth/ante/fee_tax.go`) documents that contract-message taxation was
disabled *"to remove double-taxation."* The minter is the ICP analog of that
fix. We will bring a narrow taxexemption-list proposal for the minter bridge
legs (and the burn-settlement sends) when custody approaches mainnet — with
gross-up accounting as the disclosed fallback if the community declines.

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Custody compromise = backing loss | B2b chain-key custody (no key to steal); audit before mainnet; custody never staked |
| Bridge outflow re-enters supply (lock is reversible) | Stated plainly in §1.2; the *burn* leg is the permanent mechanism |
| Params feed failure freezes transfers | Fail-closed by design; loud `refused` provenance, not silent wrong rates |
| Regulatory drift | Non-fiat asset wrap (LUNC = staking/gas asset) sits outside the GENIUS/MiCA issuance categories; no offer, no marketing of returns; terminology policy in repo docs |

## References

- Repos: `github.com/Semence2Porc/cklunc` · `github.com/Semence2Porc/forex`
- CSM context: Terra Classic proposal 12209 discourse thread `[TBD: link]`
- Tax precedent: `classic-terra/core` v4, `custom/auth/ante/fee_tax.go`
- DFINITY-facing RFC: `forex/docs/DFINITY-RFC-DRAFT.md`
