# Additional vault tests

These tests extend the existing suite without replacing its fixtures or changing production contracts.
They run offline against the vendored Uniswap v4 PoolManager. No dependency installation, fork, FFI,
environment mutation, or production deployment address is needed.

| File | Additional coverage |
| --- | --- |
| `VaultAccountingInvariant.t.sol` | Three actors, 256 random sequences of 64 calls, deposits to other receivers, partial/full withdrawals, delegated share transfers, raw donations, fee donations, both swap modes, cooldown/rebalance decisions, and irreversible emergency exits. |
| `VaultFailurePaths.t.sol` | Exact errors and state rollback after second-token pull failures, fee harvesting followed by slippage, withdrawal minima, oversized budgets, invalid receivers, invalid pool initialization, and ownership transitions. |
| `WethVaultIntegration.t.sol` | ETH-backed WETH; a sole-vault pool rebalancing in both directions with exact input and output after an empty-pool price move; manager balances matching the deposit minus swap cash flows exactly; settlement before router funding; a first deposit re-centred on the feed (one-sided basket refused, failed deposit leaves the band unchanged, only the cost is pulled); emergency payouts in wrapped tokens. |
| `MathProperties.t.sol` | Six properties with 1,000 inputs each over the exact moments (`sum` = 8 × mean, `sigma8` = ⌊8σ⌋): order and reflection symmetry, nearest-tick rounding of the whole-tick view, known distributions, minimal outward band rounding from the unrounded mean, strict 1.5σ trigger boundaries, principal rounding and price monotonicity, and budget monotonicity. Pinned cases: an unrounded-mean trigger case, zero, and one base unit. |

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
- A rebalance fires exactly when the cooldown has passed, emergency mode is off, shares other than the
  locked minimum exist, and 2·|8·tick − sum| > 3·sigma8 (the unrounded 1.5σ test).
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

## Reported defect

`.imd-findings.json` reports one medium defect, with a self-contained proof that fails on the current
code. While the vault holds no position, `deposit()` refreshes the band from the feed before quoting,
but `previewDeposit()` quotes against the stored band. After the price moves on an empty pool, the
preview offers shares for a basket that `deposit()` then refuses with `Slippage()`. The delivered
suite does not assert the preview in that state. The invariant handler compares preview and deposit
only while the vault holds a position.

The earlier low-tick rounding report (tick -658620) was addressed in the revised
`VaultMath.liquidityForAmounts` and is covered by the implementation's own `BandMath.t.sol`, so it is
no longer reported.

No live-chain fork was requested or configured. These offline integrations do not establish behavior
against a particular deployed manager/WETH pair; a chain-specific launch rehearsal remains outside
this suite.
