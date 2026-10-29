# SigmaHook Auto-Vault

A Foundry project containing a fixed-supply launch token and a Uniswap v4 liquidity vault. The vault inherits Uniswap's `BaseHook` and issues transferable ERC-20 shares. It observes the pool's execution ticks, repositions its own liquidity, and compounds its fees. Solidity **0.8.26**, Cancun EVM, optimizer and IR compilation are pinned in `foundry.toml`.

## Build and test

All Solidity dependencies, including the real v4 PoolManager used by tests, are vendored as ordinary files in `lib/`. No submodules, package installation, RPC, secrets, FFI, or filesystem permissions are needed. Compiler version 0.8.26 must be installed in Foundry's normal compiler cache.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x0dc471f47a25db42f2ae9a338992f18166f6afb6b2720570508910b719751856 forge test
forge fmt --check
```

`dependencies.lock.json` records upstream commits and archive hashes. `docs/SECURITY.md` records the security review scope and remaining deployment work. Nothing under `test/scratch/` is required by the project.

## Contracts and launch parameters

| Contract | Purpose | Constructor arguments |
| --- | --- | --- |
| `SigmaToken` | Launch ERC-20, **SigmaHook / SHK**, 18 decimals | None |
| `SigmaHook` | Vault and ERC-20 share token, **SigmaHook Vault Share / svSHK**, 18 decimals | `IPoolManager manager_`, `address owner_`, `address launchToken_`, `address factory_` |

`SigmaToken` mints exactly **1,000,000,000 × 10¹⁸** units to its deployer, the launch factory. It has no owner, additional mint, burn, transfer tax, pause, blocklist, or upgrade mechanism. Vault shares are a different token and are minted only for deposits; holding SHK alone gives no claim on the vault.

Supply distribution is the launch factory's responsibility. The hook receives no allocation at launch, cannot use the factory's LP position, and starts with zero vault shares and liquidity. Users separately deposit capital to activate the vault.

Constructor parameters map to the launch's `$poolManager`, `$owner`, `$token`, and `$factory`. No network contract address is hardcoded. Constructors perform no external calls or external code checks. Ownership is explicitly assigned to `owner_`, never inferred from the deploying factory or `tx.origin`.

The job's pair is **launch token / WETH**. The supplied launch reference instead opens **launch token / native ETH** on chain 4663. Both currency forms are implemented and tested. The trusted factory chooses the actual pair through the initialization `PoolKey`; WETH stays WETH, and native ETH stays native ETH. There is no wrapping, unwrapping, or guessed WETH address. For the launch described by the reference, initialize the native pair. A WETH deployment must use that chain's independently verified WETH address.

The factory must open a pool with fee **12,500 pips (1.25%)**, tick spacing **60**, this hook, and the constructor's launch token. The other currency is accepted from that factory-supplied key. These fixed fee and spacing values follow the supplied launch policy. Initialization reads the actual opening tick; it does not assume a 1:1 opening price or a particular token sort order. Only the factory may initialize, only once. The hook permanently binds to the resulting full pool ID. ERC-20 currency code is checked at initialization, after deployment.

## Deployment sequence

1. Build with the pinned configuration; inspect `SigmaToken` and `SigmaHook` artifacts. All libraries are internal/inlined and no link placeholders are required.
2. The launch factory deploys `SigmaToken`. Obtain the actual token, PoolManager, owner and factory addresses from the launch system. The reference supplies the owner as `0xdbeab8243f318f1bbf815d85a8a869def1510b61`; launch tooling should still encode it through `$owner`.
3. Mine a CREATE2 salt for the exact hook creation code and four ABI-encoded constructor arguments. The lower 14 address bits must be **`0x1040` (4160)**: `AFTER_INITIALIZE | AFTER_SWAP`. All other bits must be unset. `BaseHook` enforces this in its constructor.
4. `script/MineSalt.s.sol` provides a local `run(deployer, manager, owner, token, factory, start, attempts)` function. Its `deployer` is the address actually executing CREATE2. It returns a salt and predicted address, reads no environment, and broadcasts nothing. Start with 200,000 attempts; if exhausted, use the next start. Also check the predicted address has no code on the target chain. Any compiler setting, constructor value or deploying factory change requires remining.
5. The factory deploys the hook and initializes its pool atomically, using the launch's derived opening price and sorted currencies. The required initialization callback prevents initialization against the predicted hook address before its code exists.
6. Verify constructor values, bytecode, owner, pool ID, flags, currencies, fee and spacing on the actual chain. Deposit through the vault only after reviewing the initialized pool.

The network's manifest step supplies `launch.json`; this project intentionally does not supply one. No script signs or submits transactions. A real fork rehearsal and independent security review remain deployment responsibilities.

## Feed, statistics and range

Only `afterInitialize` and `afterSwap` are enabled. Each external callback inherits the PoolManager-only check. All return-delta permissions are disabled, and `afterSwap` returns its selector and zero. No callback blocks external LP additions, removals, or zero-liquidity fee collection, including during emergency mode.

Initialization seeds all eight `int24` buffer entries with the launch tick, sets the circular write index to zero, and starts the cooldown. Every subsequent swap callback reads the **post-swap `slot0.tick`** from the bound pool, replaces one entry, advances the index modulo eight, and computes:

```text
mean     = trunc_toward_zero(sum(ticks) / 8)
variance = floor(sum((tick - mean)^2) / 8)    # population variance
sigma    = floor(integer_sqrt(variance))
lower    = floor_to_spacing(mean - 3*sigma)
upper    = ceil_to_spacing(mean + 3*sigma)
```

Intermediate arithmetic uses 256-bit integers. Negative lower bounds round toward negative infinity. Equal bounds, possible at zero volatility, widen by one spacing on each side. Otherwise a zero-volatility non-grid mean uses its two surrounding grid points. Bounds are clamped to v4's usable ticks, preserving at least one spacing at either extreme. `statistics()`, `ticks(index)`, `nextSample`, `proposedBands()`, `tickLower`, and `tickUpper` expose the calculation.

The callback rebalances precisely when all of these hold:

- Emergency mode is inactive and shares exist.
- `block.timestamp >= lastRebalance + 30 minutes`.
- `2 * abs(activeTick - mean) > 3 * sigma`, using the **freshly updated** window. Equality does not trigger. With sigma zero, any nonzero deviation triggers once the cooldown expires.

This is an **eight-execution sample**, not a time-weighted oracle. Multiple swaps in a block can replace the whole window. The 30-minute condition limits rebalance frequency; it does not make the samples manipulation-resistant. That deliberate specification choice exposes LPs to adverse selection, MEV, and manipulated range selection. No guaranteed yield or protection from impermanent loss is implied.

## Rebalance and flash accounting

The swap's PoolManager unlock is already active. The hook directly:

1. Removes 100% of its old position using its fixed `POSITION_SALT`.
2. Accounts for the returned principal **and all accrued LP fees**. `modifyLiquidity`'s caller delta already includes fees; the separate fee return is used only for reporting.
3. Assigns the new bands from the fresh feed.
4. Adds as much liquidity as its two token balances and the pool's remaining per-tick capacity support, with conservative integer rounding.
5. Retains all unused balances for future cycles. The cooldown timestamp changes atomically with the successful cycle.

Positive deltas are converted into ERC-6909 claims owned by the hook. Adding liquidity consumes those claims first, then uses any raw dust with `sync → transfer → settle` (or native settlement). Every hook delta is zero before returning to the swap router. This matters on a freshly funded, one-sided pool: the router has not paid its input during `afterSwap`, so taking raw principal there could fail even though the final swap is solvent. Claims defer that transfer while preserving full backing at unlock completion. Deposits, exits and emergency activation open their own authenticated unlocks; rebalances never nest an unlock.

**Inventory assumption:** the vault does not execute balancing swaps or use an external venue. If the new range requires both tokens but inventory is mostly one-sided, only the supported portion can become LP liquidity. The remainder may be substantial, remains owned pro-rata by shareholders as raw assets or claims, and earns no LP fees until usable. This also applies when another LP fills either boundary's liquidity capacity. There is no trade at an assumed price to manufacture the missing side. `totalAssets()` includes this inventory, the position principal, and uncollected fees. No hook, performance, management, withdrawal, or keeper fee is charged.

## Deposits, shares and normal exits

Amounts always follow **currency0/currency1 order**, in the currencies' smallest units. Accounting does not assume that both currencies have 18 decimals or convert one token's value into the other at an oracle price. The share token itself uses 18 display decimals.

`previewDeposit(amount0Max, amount1Max)` returns shares and required amounts at current state. `deposit(amount0Max, amount1Max, minShares, receiver, deadline)` requires a positive `minShares`, valid receiver and unexpired deadline. Approve the hook for the required ERC-20 amounts. In a native pool, send exactly `amount0Max` as `msg.value`; unused ETH is refunded to the caller. No ETH is accepted through this entry point for an ERC-20/WETH pool.

On the first deposit, both maximum amounts are accepted, and the calculated initial liquidity determines share supply. Exactly **1,000 minimum share units** are permanently minted to the hook itself, with no recovery or redemption path, as an initial-share inflation mitigation. The depositor receives the remainder. Use a substantial first deposit and balanced budgets; tiny or unusable deposits revert. Direct donations before the first deposit accrue to this initial share supply.

Later deposits first harvest outstanding fees for existing holders, then mint the minimum of the two proportional share quotes, rounding shares down and required token contributions up. A side with zero holdings imposes no contribution. Principal is rounded up for deposit pricing, preventing rounding dilution. Only actual required ERC-20 amounts are pulled, and only from `msg.sender`. Deposits that would create zero shares or miss `minShares` revert atomically. Exact input balance checks reject transfer-tax tokens. Rebasing, taxed, blocked, or otherwise nonstandard pair tokens are unsupported; the factory must select the standard launch token and canonical WETH/native ETH.

`withdraw(shares, amount0Min, amount1Min, receiver, deadline)` burns only caller-owned shares and removes the corresponding fraction of liquidity, accrued fees and idle balances. Outputs round down. It collects fees before dividing, redeems enough claims, and returns raw pool currencies. Minimum amounts and deadlines protect the caller against stale quotes; failed payments or bounds revert the entire operation. Shares remain transferable, including during emergency mode.

Minimum shares and rounding leave a small permanent residual owned by the locked shares. The last external shareholder does not receive that residual. `minShares` and minimum withdrawal amounts must be chosen from a reviewed quote; a frontend should never silently substitute permissive bounds. External price changes and donations can change a quote before execution.

## Emergency mode and administration

Only `owner()` may call `activateEmergencyMode()`. It removes **all** vault liquidity, collects fees, redeems **all** claims, and leaves both raw assets at the hook. The owner receives nothing. Emergency mode is irreversible and prevents deposits, normal withdrawals, and further investment; use emergency withdrawals instead. Swaps and other LPs' positions remain usable, and the execution feed continues updating.

Anyone may call `emergencyWithdraw()` to burn **their own entire share balance**, or `emergencyWithdraw(shares, receiver)` for a partial redemption or different destination. Each receives `floor(rawBalance * shares / totalSupply)` of each asset. No PoolManager call, oracle, keeper, cooldown, or owner's further approval is needed. State updates and the share burn precede payments; a reentrancy guard covers all asset entry and exit paths. A recipient that rejects ETH can choose another receiver without losing shares, since failed transfers roll back.

The owner can transfer ownership through the two-step `transferOwnership` / `acceptOwnership` flow. Renunciation is disabled to retain an emergency operator. There is no asset-sweep, manual price setter, manual range override, pool reassignment, upgrade, arbitrary external-call, or additional fee power. Accidental transfers of unrelated assets have no recovery function.

## After launch

No external-service setter is needed: manager, owner, token and factory are constructor-bound, and the factory's initialization binds the pool. Verify those values before accepting user deposits. For WETH, the launch operator must verify the other currency against the target chain's official deployment and token interface.

The owner should use an operationally accessible, reviewed ownership arrangement, monitor `SampleRecorded`, `FeesCollected`, `Rebalanced`, and vault balances, and activate emergency mode on a strategy or integration failure. Watch one-sided idle balances, unexpected pool prices, liquidity at the range boundaries, failed swaps and the time since the last rebalance. A quiet pool produces no new samples or automatic cycles; no keeper can force a rebalance outside the specified trigger. Swappers pay the extra gas of triggered cycles.

The launch operator must verify Cancun compatibility, the actual manager implementation, fee configuration and atomic factory initialization, rehearse deposits/swaps/emergency exits on the target deployment, and arrange independent adversarial review before accepting public capital. Local tests use real v4 core code, but are not a fork rehearsal or an independent audit.

## Hook configuration record

```json
{
  "hook": "BaseHook",
  "name": "SigmaHook",
  "pausable": false,
  "currencySettler": true,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": "ERC20" },
  "permissions": {
    "beforeInitialize": false,
    "afterInitialize": true,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": false,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

The utility fields describe the behavior: settlement is implemented directly in `_settle`, and casts are bounded before narrowing. The hook itself uses ordinary storage for its guard and unlock latch; the v4 PoolManager requires Cancun transient storage. The vendored `BaseHook` is from Uniswap's `v4-hooks-public` repository; its `ImmutableState` comes from `v4-periphery`.

Upstream integration references: [v4 PoolManager implementation](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/PoolManager.sol), [v4 hook dispatch](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/libraries/Hooks.sol), and [BaseHook](https://github.com/Uniswap/v4-hooks-public/blob/82de6aa6de5c3e387fa5a088af6977f14f66e314/src/base/BaseHook.sol). Dependencies retain their own upstream licenses; see `lib/` and the lockfile.
