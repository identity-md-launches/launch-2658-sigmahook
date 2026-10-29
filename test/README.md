# Additional vault tests

These tests extend the existing suite without replacing its fixtures or changing production contracts.
They run offline against the vendored Uniswap v4 PoolManager. No dependency installation, fork, FFI,
environment mutation, or production deployment address is needed.

| File | Additional coverage |
| --- | --- |
| `VaultAccountingInvariant.t.sol` | Three actors, 256 random sequences of 64 calls, deposits to other receivers, partial/full withdrawals, delegated share transfers, raw donations, fee donations, both swap modes, cooldown/rebalance decisions, and irreversible emergency exits. |
| `VaultFailurePaths.t.sol` | Exact errors and state rollback after second-token pull failures, fee harvesting followed by slippage, withdrawal minima, oversized budgets, invalid receivers, invalid pool initialization, and ownership transitions. |
| `WethVaultIntegration.t.sol` | ETH-backed WETH, both trade directions with exact input/output, zero initial input-token reserves, rebalance settlement before router funding, and emergency payouts in wrapped tokens. |
| `MathProperties.t.sol` | Six properties with 1,000 inputs each: statistical symmetries, known distributions, minimal outward band rounding, strict trigger boundaries, principal rounding/price monotonicity, and budget monotonicity. Explicit zero and one-unit cases supplement them. |

## Independent accounting model

The accounting campaign deliberately uses a pool whose sole LP is the vault. Its signed token ledger
starts with the known 170-token deposits on each side, then records measured depositor/recipient wallet
flows, donations, and the router's swap deltas. It never updates that ledger from `totalAssets()`.
After every action:

- Physical manager plus hook balances must equal the external cash-flow ledger exactly.
- Reported vault assets cannot exceed that backing; assets stranded in the manager are bounded by
  four base units per accounting action, allowing only integer rounding from principal and fees.
- Each actor's shares and total supply must match a separate mint/burn/transfer ledger.
- The circular feed must match an append-only history of actual post-swap `slot0` ticks.
- Emergency activation must remain permanent, with no liquidity or claims left in the manager.

The bounded tick domain is [-600, 600], and budgets include zero through five tokens. Fees, raw
donations, and trades are distinct actions. Bounds keep successful actions affordable; invalid zero
share quotes explicitly test the expected revert. Repeated deposit/withdraw cycles also assert that
the caller cannot gain either token. Every completed random sequence activates emergency and redeems
every actor's entire share balance. A deterministic scenario exercises every handler action and checks
its successful-operation counters, so the campaign is supplemented by a non-vacuous branch check.

The five discovery passes considered conservation, state transitions, round-trip rounding, value
extraction/liveness, and vault/AMM properties. Source anchors are `SigmaHook.deposit/withdraw`,
`_afterSwap`, `_assets`, `_quoteDeposit`, `_emergencyWithdraw`, and both math libraries. Pool reserves
are not assumed to have a constant product across rebalances; principal losses from trading are
accounted for using swap cash flows. The existing background-LP invariant remains complementary.

## Reproduction

```sh
FOUNDRY_FUZZ_SEED=0x0dc471f47a25db42f2ae9a338992f18166f6afb6b2720570508910b719751856 forge test
forge build
```

Run counts are embedded in the new test source. For builds restricted to the test directory, append
`--out test/scratch/out --cache-path test/scratch/cache` to either command. No delivered test imports
anything from `test/scratch/` or `.imd/reads/`.

## Confirmed limitation

A separate defect report in `.imd-findings.json` includes a self-contained failing Foundry proof:
at tick -658620, a 1,000-token currency0 deposit with one base unit of currency1 leaves approximately
496.626 currency0 tokens idle despite sufficient counterpart tokens and tick capacity. Early rounding
in `VaultMath.liquidityForAmounts` causes this. The passing suite does not assert that this behavior
is correct; the failing proof is supplied with the report for the implementation author.

No live-chain fork was requested or configured. These offline integrations do not establish behavior
against a particular deployed manager/WETH pair; a chain-specific launch rehearsal remains outside
this suite.
