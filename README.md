# CKLUNC — chain-key LUNC on the Internet Computer (in development)

[![CI](https://github.com/Semence2Porc/cklunc/actions/workflows/ci.yml/badge.svg)](https://github.com/Semence2Porc/cklunc/actions/workflows/ci.yml)

An ICRC-1/ICRC-2 twin of LUNC backed 1:1 by LUNC in minter custody, with
**dynamic tax parity**: LUNC's burn-tax parameters are mirrored live from the
chain (fail-closed on staleness), and taxed transfers burn on both chains.

## Why tax parity (the narrative)

**CKLUNC is LUNC's fast lane.** Terra Classic settles value; ICP executes logic —
games, agent economies, DEX routing — at web speed with consensus timestamps.
Tax parity means every CKLUNC leg still burns into the LUNC economy, so ICP-side
volume *grows* LUNC's burns instead of leaking to a tax-free twin.

- **Mirroring works in both directions.** If LUNC's rate rises to 2%, the
  mirrored rate rises with the next feed refresh — no code change, no vote.
- **Governance can only go cheaper, never dearer.** The override may set the
  CKLUNC rate strictly below the mirrored rate (including 0% for
  liquidity-routing regimes). ICP-side > LUNC-side is structurally impossible:
  the twin must never cost more than the chain it mirrors. If the mirrored rate
  later drops below the override, parity wins automatically.
- **The feed is cheap.** Transfers never make HTTP outcalls — the rate is
  pushed by the params feed and cached. At one refresh per day (the shipped
  default freshness bound) an N-LCD heartbeat costs ~$0.0002/day in cycles.
  The bound is governance-adjustable (1h–7d) without redeploying.
- **Honest provenance.** Every taxed response carries `rate_mode`:
  `parity` (mirrored rate applied), `override` (governed lower rate applied),
  or `refused` (stale params — fail-closed, nothing executed).
- **Asset-agnostic core.** The tax module mirrors Cosmos Dec math, not LUNC
  specifics — ckEUTC and ckUSTC twins reuse it unchanged.

> **STATUS: NOT PRODUCTION. NO MAINNET CUSTODY. NO REAL KEYS.**
> B0 (tax-parity core) and B1 (ICRC-1/2 ledger) are complete; phases B2a
> (dev-custodial bridge) and B2b (threshold-ECDSA chain-key custody) land
> next; until B2b + a security review, this repo is testnet-only by design.
> See `lunc-skills/skills/cklunc-integration/SKILL.md` for the
> consumer-facing interface contract.

## What is complete today

- `src/backend/Tax.mo` — exact integer tax-parity math: Cosmos Dec parsing
  (10^-18 fixed point), floored tax, `net + tax = amount` conservation, sanity
  bounds (0 ≤ rate ≤ 5%; the live 2026-09-13 rate 0.015 sits inside them).
- `src/backend/main.mo` — the minter core: params feed with fail-closed
  freshness (24h bound, epoch 0 = refuse to execute), `taxed_transfer` +
  preview with `rate_mode` provenance, the governed rate override
  (`setRateOverride` accepts only sane rates strictly below the mirrored rate;
  `clearRateOverride` returns to parity), the freshness knob
  (`setParamsMaxAgeNs`, bounded 1h–7d), the settlement burn ledger (ICP-side
  burns accumulate into epochs, `markSettled` links the LUNC txid per epoch),
  stats. Security posture: **all timestamps are canister-consensus time**
  (callers never supply clocks — a caller-supplied `nowNs` could dress stale
  params as fresh), all three admin endpoints are **controller-gated**
  (pre-B2b the deployer; after decentralization the controllers are the
  governing canisters), and the ledger is an O(1)-amortized mutable backing
  array (no per-burn O(n) rebuild).
- `src/backend/Icrc.mo` — inline ICRC-1/ICRC-2 ledger. **Why inline:** the
  canonical Motoko ledger (`dfinity/icrc1-mo`) was 404-unreachable during this
  build and the mops registry is DNS-blocked on the dev network, so the
  dependency could not be vendored verifiably; the wire surface here was
  validated against the official `dfinity/ICRC-1` candid files instead.
  Implements transfers (with burn-to-minting-account semantics),
  ICRC-2 approve/transfer_from (CAS via `expected_allowance`, zero-amount
  revoke), flat fee (10_000 base units) **burned outright** — the B1 PoC
  model, chosen so the exact invariant `sum(all balances) == totalSupply`
  holds after every operation (asserted in tests); canonical
  fee-to-minting-account accounting is adopted at the B6 migration together
  with the official Rust ledger suite.
- `src/backend/main.mo` — ledger surface wired to the minter: `icrc1_*`
  queries (name/symbol/decimals/fee/total_supply/minting_account/balance/
  supported_standards), `icrc1_transfer`, `icrc2_approve`/
  `icrc2_transfer_from`/`icrc2_allowance`, controller-gated `cklunc_mint`
  (the B2a bridge entry) and `set_minting_account`. `taxed_transfer` now
  executes: the tax portion is burned straight from the caller's balance
  (fail-closed on insufficient balance); the full ICRC-2 pull flow wires in
  at B2.
- `test/main.test.mo` — unit suite covering the live rate format, conservation
  on >2^63 amounts, floor-to-zero on dust, and the sanity bound (which the test
  *caught being wrong* during development — it originally rejected the live
  1.5% rate), plus the ledger suite: fee/burn accounting, the supply invariant
  after every operation, BadFee/BadBurn/CreatedInFuture, the
  approve→transfer_from→revoke lifecycle, CAS rejection, and subaccount
  identity separation. The suite caught a real bug on first run (burn
  transfers credited the minting account instead of destroying — fixed).

```bash
mops test && mops build   # green in WSL with mops 2.19.2, core 2.0.0
```

## Roadmap (approved plan)

| Phase | Scope | Status |
|---|---|---|
| B0 | scaffold, WSL CI | ✅ |
| B1 | ICRC-1/2 ledger (inline `Icrc.mo`, decimals 6, fee/tax burn, supply invariant) | ✅ |
| B2a | dev-custodial bridge + ICRC-2 pull wiring | next |
| B3 | deposit detection (LCD outcalls, idempotent mint, breaker) | planned |
| B3.5 | live tax-params feed (N-LCD majority, bounds, fail-closed) | planned |
| B4 | accounting (invariant: held − burned ≥ supply), stable structures | planned |
| B2b | threshold-ECDSA chain-key custody (coinType 330, `terra1` vectors) | planned |
| B5 | optional CKLUNC-settled HTTP-402 paywall | exploratory |
| B5.5 | staged mainnet track: testnet → capped mainnet custody (deposit ceiling + circuit breaker live) → open custody as metrics prove out | planned |
| B6 | NNS adoption ask (SNS fallback): governance takes over as controller — same canister IDs, balances survive (`init_state` export; trivial at pre-launch supply); ledger may migrate to the official Rust ICRC-1 suite in the same step | planned |
| B7 | fiat-referenced twins (ckUSTC / ckEUTC / ckEURC) — **gated on legal review** (GENIUS issuance / MiCA ART analysis); same generic core, sequenced after mainnet custody is proven | gated |

**No permission gate to build.** Chain-key custody reads and writes the public
Terra Classic ledger; to the chain, the ICP minter is just another wallet (the
ckBTC/ckERC-20 pattern — no source-chain permission needed, and Cosmos chains
all sign with secp256k1, which threshold ECDSA covers). B6 is an *adoption*
ask, not a deployment gate. LUNC governance enters the picture only for the
later taxexemption ask and an optional canonical-twin endorsement (see
`docs/PROPOSAL-LUNC-GOVERNANCE.md`, dormant).

## Invariants

1. **Backing:** minter-held LUNC − settled-and-pending underlying burns ≥ CKLUNC
   supply (property-tested at B4).
2. **Conservation:** every taxed transfer satisfies `net + tax = amount` exactly.
3. **Fail-closed:** stale tax params or stale deposit oracle freeze the affected
   operations loudly; nothing executes on stale data.
4. **Tax neutrality of the bridge:** the LUNC leg pays LUNC's tax natively;
   CKLUNC legs pay via `taxed_transfer` — never both.

## Bridge tax mechanics (B2b/B3 design input, verified against core v4)

From `core/custom/auth/ante/fee_tax.go`: the burn tax applies to `MsgSend`,
`MsgMultiSend`, `MsgSwapSend`, and contract execute/instantiate funds — checked
against the `x/taxexemption` address-pair list. Two consequences:

- **IBC transfers (`MsgTransfer`) are not in the taxed message set at all** —
  IBC bridging out of LUNC pays no burn tax. (Not our rail, but good to know.)
- **Our bridge's LUNC legs ARE plain `MsgSends`** — deposits to the minter and
  burn-settlement sends are taxed unless the (minter, counterparty) pairs get a
  governance exemption. The README invariant above forbids double taxation, and
  the chain has already ruled this way once: the fee_tax.go comment records that
  contract-message taxation was changed *to remove double-taxation*. The
  minter is the ICP analog of that fix — the exemption ask (or explicit
  gross-up accounting as the fallback) must be a prepared governance item
  before mainnet custody, not an afterthought.
- **Burn-settlement sends** (Phase 2: freed LUNC → dead address) are also
  MsgSends; if not exempted, burning X costs X + X×rate. Prefer the exemption;
  otherwise the epoch math needs a tax buffer.

No rate-level risk exists in the override: backing is 1:1 at ANY rate in
[0, mirrored] — `held − (settled + pending) ≥ supply` holds regardless of how
small the ICP-side tax is. A lower override means less burn contribution, not
insolvency. The dangerous direction (charging MORE than the mirrored chain,
releasing less LUNC than burned CKLUNC) is structurally blocked by
`override < mirrored`.
