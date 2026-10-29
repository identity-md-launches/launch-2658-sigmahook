# SigmaHook — keeper flywheel and ERC-4626 vault

Solidity 0.8.26 / Cancun Foundry project. `SigmaHook` manages one Uniswap v4 position and a basket of its two currencies. `SigmaVault`, deployed automatically by the hook constructor, inherits the vendored OpenZeppelin `ERC4626` implementation and issues the transferable **svSHK** vToken. Existing SHK token source and supply are unchanged.

## Build and verify

```sh
forge build
FOUNDRY_FUZZ_SEED=0x075f6677a0a3d9b87b6715c5bc40f83a64604edac943aab568aa55927880dd0c forge test
forge fmt --check
```

Dependencies are already vendored in `lib/`; the build configuration and dependencies are unchanged. Tests use the real vendored PoolManager, actual CREATE2 deployment with the required hook bits, and local tokens. The fixture loads Foundry-generated contract artifacts to avoid embedding all creation bytecode in every test. No RPC, keys, environment reads, network installation, FFI, or additional filesystem permissions are required by the tests. The test seed above is supplied to Forge, not read by contracts or test cheatcodes.

## Architecture and units

| Contract | Responsibility | Units |
| --- | --- | --- |
| `SigmaToken` | Existing fixed-supply SHK launch token | SHK base units |
| `SigmaHook` | Pool position, idle balances/claims, basket entry/exit, statistics, keeper fee pipeline | `sSHK` basket receipts; two-currency `totalAssets()` |
| `SigmaVault` (`hook.vault()`) | OpenZeppelin ERC-4626 wrapper | `asset()` is the hook's ERC-20 basket receipt; `totalAssets()` is receipts held; shares are `svSHK` |
| `SigmaMath` (`hook.math()`) | Stateless calculation/view helper, immutable and without custody | Band, price, position and liquidity calculations |
| `PermanentTokenLock` (`hook.burnSink()`) | Irrecoverable buyback custody if the token rejects zero-address transfers | Launch tokens held forever |

ERC-4626 specifies **one ERC-20 asset**. The existing strategy owns two currencies, including native ETH on the pinned launch. The chosen wrapper asset is therefore its basket receipt, rather than a manipulable spot-price conversion into SHK or an invented WETH address. Each receipt owns its fraction of pool principal, net uncollected fees, idle ERC-20/native balances, and ERC-6909 claims. Wrapping receipts preserves that ownership. Yield increases the underlying value of a receipt; it need not increase the number of receipts shown by ERC-4626 `totalAssets()`.

The hook's legacy two-budget methods are basket methods, not ERC-4626 methods. The canonical ERC-4626 address is **`hook.vault()`**, not the hook. The wrapper inherits all standard previews, conversions, limits, Deposit/Withdraw events, mint/redeem/withdraw flows and delegated withdrawal allowance checks. `underlyingAssets(vTokenShares)` provides a rounded-down look-through quote in pool currency order. Its conversion into receipts uses no price oracle; the look-through pool amounts reflect the manager's current position state. OpenZeppelin's virtual asset/share protection remains enabled; positive deposits that would mint zero vTokens revert. The wrapper has no admin, upgrade, sweep or external strategy investment function.

Typical entry:

1. Read `poolKey()` and `previewDeposit(max0,max1)` on the hook. Approve its exact ERC-20 requirements; for a native pair send `max0` ETH.
2. Call `hook.deposit(max0,max1,minReceipts,receiver,deadline)`. The first deposit refreshes the range and mints receipt shares based on actual manager debits. Its 1,000 genesis receipt units remain permanently locked in the hook.
3. Approve the receipt amount to `hook.vault()`, then call the wrapper's `deposit(receipts,receiver)` or `mint(vTokenShares,receiver)`.

Typical exit: call the wrapper's `redeem(vTokenShares,receiver,owner)` or `withdraw(receipts,receiver,owner)`, then call `hook.withdraw(receipts,min0,min1,receiver,deadline)`. ERC-4626 withdrawals return receipts; basket exits return the two pool currencies. Each approval is to its specific contract. Shares of either layer can be transferred normally. During emergency mode unwrap to receipts and call `hook.emergencyWithdraw`, including its partial/alternative-recipient overload.

## Defect fixes

**Exact first deposit.** Preview and execution use the same freshly computed range and per-tick capacity. Only predicted rounded liquidity costs are pulled from the caller. Inside the unlock, `modifyLiquidity` returns the authoritative currency debits; `amount0Consumed` and `amount1Consumed` determine paid liquidity and the initial share mint. Any overpayment is refunded to the caller in that unlock, including the entire unused native budget. Preexisting donations are excluded from the first deposit's investment budgets. Existing holders' fees are harvested before later deposit pricing; pending fee allocations are excluded from LP NAV.

**Inventory starvation.** The fixed 300-tick limit has been removed from the strategy. An internal trade can traverse the selected statistical band, stopping one tick inside its edge. The hook recalculates affordable liquidity after the actual trade and can make bounded additional ratio corrections if it would otherwise mint zero. Empty active liquidity is not traded merely to move slot0. If no nonzero position can be funded, `InvestmentDeferred` and `investmentPending` make the condition explicit. Assets remain in persistent raw balances/ERC-6909 claims and remain redeemable. `retryInvestment(key)` is public, pays no bounty, and retries the selected range without resetting the cooldown or choosing a new range. A later eligible keeper rebalance can also select a new range. Deposits into a deferred vault preserve the selected range and cannot bypass this gate. EVM transient storage is transaction-scoped and cannot preserve assets between calls; it is not used as an inter-transaction escrow.

**Native ETH.** `receive()` accepts only the PoolManager or the once-configured `WETH` source. `accountedNative` tracks native deposits, manager receipts, payments and refunds. `rescueStrayETH()` is owner-only and sends **only `address(this).balance - accountedNative`** to the current owner. Forced ETH and unsolicited WETH-source ETH are outside LP NAV; the owner cannot rescue native pool principal, claims, fee reserves or emergency withdrawal assets. WETH remains wrapped in a WETH pair; the strategy never unwraps it.

## Keeper execution and fee accounting

`afterSwap` validates the bound pool, reads the execution tick, writes one circular-buffer slot and emits `SampleRecorded(index,tick)`. It performs no statistics, swaps, liquidity changes, fee payouts or rebalance. The buffer has eight execution samples, initially seeded with the launch tick. Own internal swaps do not reenter the hook under v4 dispatch rules.

Anyone may call **`flashRebalance(PoolKey key)`**. It reverts unless the vault is live, the key matches, external receipts exist, at least 30 minutes have passed since `lastRebalanceTimestamp()`, and the current tick lies **strictly beyond 1.5 sigma** from the running SMA. Equality does not qualify. The time gate uses `block.timestamp`. Statistics retain fractional precision in eighths of a tick. The new range is SMA ± 3 sigma, rounded outward to the tick-spacing grid; zero sigma gets a nonempty range.

One hook-initiated unlock removes the old position, allocates harvested fees, processes buybacks, pays the caller, balances inventory and redeploys principal plus net yield. Only the manager's separate `feesAccrued` result is treated as fees; `callerDelta` already contains those fees and is never counted twice.

For each currency and harvest, with fee amount `F`:

- Buyback reserve: `floor(F * 2000 / 10000)` (20%).
- Keeper reserve: `floor(F * 100 / 10000)` (1%).
- LP yield: the remainder (79% plus integer rounding dust).

These reserves are recognized on **every** harvest, including deposits/withdrawals, so those paths cannot compound or pay out the buyback/bounty allocations. `feeLiabilities()` also includes the corresponding uncollected allocations. Raw token donations are LP assets and do not incur this fee split. Principal is never charged a 21% fee.

The launch-token allocation is disposed directly. The paired-currency allocation is swapped in the bound pool into the **same existing launch token**, using actual swap debits/credits and the statistical range price limit. The complete available keeper reserve is paid in its original pool currencies to the `flashRebalance` caller, before reinvestment. A failed receiver or token transfer reverts the entire operation, including the timestamp, burn/lock and position changes; another keeper can try. A reentrancy guard covers asset entrypoints and keeper payouts.

If the paired buyback cannot be fully filled (for example the vault was the only LP), its unspent amount stays in `burnReserve0/1`, excluded from LP assets and future investment budgets. `BuybackDeferred` reports it. A later eligible rebalance retries it. Buyback output is disposed immediately, and the 79% remains available for the new range. This preserves fee allocation without fabricating an external router or blocking regular swaps for lack of a buyback venue.

## Burn policy decision

The pinned live SHK contract inherits OpenZeppelin ERC-20, rejects `transfer(address(0),amount)`, and exposes no public burn or upgrade function. A literal unconditional zero-address transfer would make every fee-bearing rebalance fail. The selected compatibility policy is: attempt the requested zero-address transfer; if the token refuses it, transfer the exact launch-token amount to the newly created **`PermanentTokenLock`**. The lock has no owner, functions, approval path, withdrawal, self-destruct, delegatecall or upgrade mechanism. No arbitrary address or owner-controlled burn recipient is used.

`LaunchDisposed(amount,zeroAddressTransfer)` distinguishes the paths. For the existing SHK token the lock path **reduces circulating supply but does not reduce `totalSupply()`**. Neither the launch token nor its supply is replaced or re-minted. Even for a token accepting zero-address transfers, no total-supply decrease is assumed without that token implementing it. This explicitly resolves the incompatible burn instruction that stopped the earlier attempt.

## Deployment parameters and existing deployment

The four hook constructor arguments remain `(IPoolManager manager_, address owner_, address launchToken_, address factory_)`. They must be nonzero. Ownership is explicitly assigned to `owner_`, not the deploying factory. CREATE2 hook bits remain `0x1040` (`afterInitialize` and `afterSwap`, no return-delta flags). Re-mine the salt for the final creation code with `script/MineSalt.s.sol`; changing code changes the CREATE2 hash. The constructor creates its canonical wrapper, stateless math helper and permanent lock. There is no separate token deployment in this update.

Factory-only initialization binds one pool permanently. Required pool fee is 12,500 pips (1.25%), spacing is 60, and one currency must be the immutable launch token. The other currency may be native ETH or a standard ERC-20. There is no pool reassignment or upgrade.

Pinned project inputs identify Robinhood Chain, chain ID **4663**, with:

| Item | Pinned address |
| --- | --- |
| Existing SHK token | `0x4fe865ad3b3ef64b2af9c38c78abf5c6e68c1164` |
| Existing immutable Sprint 1 hook | `0xcc0551d738d964a2d68ac3674e7fe4a2e69f1040` |
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |

The pinned live pool pairs SHK with **native ETH**, not WETH. These are input records, not newly verified on-chain addresses. No transactions, deployment, migration, or token mint were performed by this assignment. Updating source cannot patch the immutable live hook. Deployment operators must arrange a reviewed new hook/pool using the existing SHK token and a voluntary exit/re-entry migration for existing LPs. Existing shares and deployed ABIs do not change retroactively. The historical `launch.json` is not a migration instruction and is not rewritten by this task.

The network input marks `extendedSwapParams: true`, while the protected vendored core uses upstream three-field `SwapParams`. Local integration tests establish correctness against that vendored ABI, not compatibility with an undocumented extended on-chain selector. Before any deployment, the operator must verify the target manager's swap/callback ABI and resolve any extension through the deployment integration. This delivery does not guess extra fields or claim a fork rehearsal.

## After launch

- **Optional WETH source:** owner calls `setWETH(verifiedWrappedEtherAddress)` once, only if WETH-source ETH reception is needed. Obtain and verify the canonical deployment and bytecode from the target chain's official registry. The supplied network inputs contain no WETH address, so none is invented. Until configured, only the PoolManager may send ETH through `receive()`; native-pool trading, deposits, withdrawals, fee collection and rebalancing already work. The setting only authorizes an ETH sender, not an external router or asset allowance.
- **Operator:** verify constructor arguments, hook flags, `poolKey()`, canonical `vault()`, its `asset()`, and `burnSink()`; verify Cancun and manager ABI compatibility, factory initialization, fee/spacing and currency order. Publish the new hook/wrapper addresses separately from the historical deployment. Never redeploy or re-mint SHK for migration.
- **Keepers:** monitor ticks, statistics, timestamp, LP inventory and fee reserves. Simulate `flashRebalance(key)` and submit when eligible; accept native ETH if the pool uses it. Gas is the keeper's expense; 1% fees do not guarantee profit. Monitor `InvestmentDeferred` and retry when liquidity returns. Deferred buybacks need a future eligible keeper rebalance and available paired liquidity.
- **Owner:** operate the two-step ownership transfer and irreversible emergency exit, and rescue only stray ETH. Emergency activation collects all pool assets, cancels outstanding unexecuted fee allocations back to LPs, and pays the owner nothing. Thereafter holders redeem raw assets without the manager. The cancellation avoids orphaned fee reserves when no keeper job remains. Ownership cannot be renounced.
- **Release reviewer:** perform an independent adversarial review and actual-chain integration rehearsal before public capital. See [security review](docs/SECURITY.md) and [test coverage](test/README.md).

The execution-sample SMA is not a TWAP: eight swaps can change the whole feed in one block. Range-bounded orders remain exposed to sandwiching and adverse prices. Thin liquidity can leave capital idle; fees and the buyback do not guarantee positive returns. LPs retain minimum-output/deadline controls on basket entry/exit and should apply transaction-level slippage checks when wrapping receipts.
