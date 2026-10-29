# Verification coverage

All tests use the pinned Solidity 0.8.26/Cancun configuration and vendored dependencies. They run offline, with no environment reads or mutations, RPC, FFI, or custom filesystem permissions. Fixtures use Foundry's compiled artifact loader and actual CREATE2 construction, preserving hook address validation and constructor behavior. Nothing delivered imports `test/scratch/` or `.imd/reads/`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x075f6677a0a3d9b87b6715c5bc40f83a64604edac943aab568aa55927880dd0c forge test
forge fmt --check
```

| Suite | Coverage |
| --- | --- |
| `Flywheel.t.sol` | Callback only records samples; pool/cooldown/deviation/empty/emergency gates; exact 20/1/79 allocation; actual-caller bounty and ordering; zero-address-compatible and permanent-lock disposal, deferred buyback single-spend accounting; harvested fee reservations; deferred inventory, retry, no deposit-based range bypass, live exit and dislocation fuzzing. |
| `SigmaVault.t.sol` | Canonical OpenZeppelin ERC-4626 asset and metadata; all four standard entrypoints and previews; rounding; delegated exit allowance failures; transferable ownership of LP value, fees and idle donations; inflation refusal; unwrap/emergency exit with unavailable manager. |
| `NativeSafety.t.sol` | Fuzzed asymmetric first deposits after price displacement, exact costs/refunds and preview agreement; authorized receive sources and one-time WETH setting; owner rescue bounded to surplus; rejected/reentrant keeper recipients and complete rollback. |
| `SigmaHook.t.sol` | Hook flags, explicit ownership, initialization, feed wrap, entry/exit bounds, fees and dilution, fresh initial ranges, large trends, real keeper calls, emergency behavior, bytecode size and round-trip fuzzing. |
| `NativeVault.t.sol` | Native refunds, both swap directions/modes, callback sampling with cold manager reserves, keeper settlement, emergency exits without manager, rejecting and reentrant ETH recipients. |
| `Adversarial.t.sol` | Taxed and callback tokens, saturated tick capacity, extreme prices, exact CREATE2 salt mining, prepaying swap router safety, unauthorized emergency redemption. |
| `WethVaultIntegration.t.sol` | Actual ETH-backed WETH; both swap directions and input/output modes; exact manager cash flows including fee liabilities; fresh first-deposit bands; wrapped-token emergency payouts. |
| `VaultFailurePaths.t.sol` | Exact errors and complete rollback after failed token pulls, fee harvest followed by slippage, output minima, invalid receivers/budgets, pool initialization and ownership transitions. |
| `VaultAccountingInvariant.t.sol` | Independent external cash-flow and share ledgers; three actors, 256 sequences of 64 calls; deposits, exits, fees, raw donations, trades and transfers; ring history; full emergency exits. |
| `VaultInvariant.t.sol` | Random deposits, exits, transfers, swaps, donations, elapsed time, permissionless keeper calls and emergencies; exact token conservation including permanent lock; zero flash deltas and manager lock; position consistency. |
| `BandMath.t.sol`, `MathProperties.t.sol` | Full tick domain, fractional moments, strict deviation boundaries, negative grid rounding, budget and principal rounding, extreme prices and per-tick limits. Six properties use 1,000 inputs each. |
| `SigmaToken.t.sol` | Unchanged fixed-supply token metadata, transfer/allowance behavior and lack of additional mint/admin paths. |

The independent accounting model records actual wallet and router flows rather than deriving its book from `totalAssets()`. LP NAV **plus fee liabilities** must match physical custody within an operation-count rounding allowance. The sample-only swap callback must never update the keeper timestamp. The complementary background-LP invariant includes actual keeper executions and checks all physical token holders, including the permanent lock and keeper wallet.

These tests do not establish compatibility with the pinned chain's extended swap ABI or constitute an independent security audit. Deployment and adversarial review responsibilities are documented in the root README.

## Local verification result

Final verification with Solidity 0.8.26 and the seed above: **104 tests passed, zero failed, zero skipped**, across 13 suites. `forge build` and `forge fmt --check` passed. The hook runtime is 23,438 bytes (EIP-170 maximum: 24,576); its initcode is 37,016 bytes (EIP-3860 maximum: 49,152). SigmaHook, SigmaVault, SigmaMath and PermanentTokenLock have no unresolved linked-library references. Forge emits lint advisories about bounded casts, timestamp gates, exact balance checks and guarded external calls; this result is not a clean static-analysis audit.
