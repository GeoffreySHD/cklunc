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
> Phases B2a (dev-custodial bridge) and B2b (threshold-ECDSA chain-key custody)
> land after this core; until B2b + a security review, this repo is testnet-only
> by design. See `lunc-skills/skills/cklunc-integration/SKILL.md` for the
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
- `test/main.test.mo` — unit suite covering the live rate format, conservation
  on >2^63 amounts, floor-to-zero on dust, and the sanity bound (which the test
  *caught being wrong* during development — it originally rejected the live
  1.5% rate).

```bash
mops test && mops build   # green in WSL with mops 2.19.2, core 2.0.0
```

## Roadmap (approved plan)

| Phase | Scope | Status |
|---|---|---|
| B0 | scaffold, WSL CI | ✅ |
| B1 | ICRC-1/2 ledger deploy (decimals 6, minter-separated) | next |
| B2a | dev-custodial bridge + ICRC-2 pull wiring | planned |
| B3 | deposit detection (LCD outcalls, idempotent mint, breaker) | planned |
| B3.5 | live tax-params feed (N-LCD majority, bounds, fail-closed) | planned |
| B4 | accounting (invariant: held − burned ≥ supply), stable structures | planned |
| B2b | threshold-ECDSA chain-key custody (coinType 330, `terra1` vectors) | planned |
| B5 | optional CKLUNC-settled HTTP-402 paywall | exploratory |

## Invariants

1. **Backing:** minter-held LUNC − settled-and-pending underlying burns ≥ CKLUNC
   supply (property-tested at B4).
2. **Conservation:** every taxed transfer satisfies `net + tax = amount` exactly.
3. **Fail-closed:** stale tax params or stale deposit oracle freeze the affected
   operations loudly; nothing executes on stale data.
4. **Tax neutrality of the bridge:** the LUNC leg pays LUNC's tax natively;
   CKLUNC legs pay via `taxed_transfer` — never both.
