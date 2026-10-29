# Security review record

This is an implementation self-review, not an independent security audit. No on-chain deployment, fork rehearsal, static-analysis service, formal verification or independent reviewer was used for this delivery. The requester-supplied security references informed the review; the task's behavior and acceptance criteria take precedence over examples in those references.

## Trust boundary

- `PoolManager` is immutable and must be the reviewed v4 implementation. BaseHook checks its identity for every callback, including disabled callbacks. The unlock callback additionally requires an outstanding locally initiated unlock.
- `factory` is immutable and is the only initializer. It chooses the paired currency and initial price, must include the immutable launch token, and cannot subsequently rebind the hook.
- Owner authority consists of irreversible emergency activation and two-step ownership transfer. There is no route to withdraw another holder's assets or change trading logic.
- Pair tokens must be standard non-rebasing ERC-20s (or native ETH), without transfer taxes, callbacks that require reentry, freezes, or confiscation. Incoming amounts are checked exactly, and ERC-20 returns are handled safely. This does not make arbitrary malicious tokens safe.
- All pool state, share balances and raw balances are public. View quotes are not an oracle or a promise of future output.

## Reviewed fund paths

| Path | Accounting and authorization | Verification |
| --- | --- | --- |
| Initialize | PoolManager callback, trusted factory sender, exact fee/spacing, launch-token inclusion, single pool ID | Mined production deployment, seeded buffer, unauthorized and second-pool refusal, extreme initial ticks |
| Deposit | Caller-only token pull; harvest fees before pricing; shares floor / assets ceil; native excess excluded from NAV and refunded | Proportional deposits, fee dilution, invalid inputs, minimum shares, taxed token rollback, callback reentry |
| Ordinary exit | Burn caller's shares; harvest; proportional idle balances plus fractional position burn; redeem claims; enforce bounds | Rounding conservation fuzz, unauthorized burns, output bounds, expired calls |
| Rebalance | Fresh slot0 sample; exact-mean deviation in eighths; elapsed timestamp; external shares only; remove all old LP; balancing trade bounded by band edge, tick cap and deadband, skipped in an empty pool; reinvest principal, fees and dust | Cooldown boundary, sample wrap, same-range compounding, old position zero, tick-cap saturation, trend cycles in thin and deep pools, emptied vault stays quiet, resting-tick trigger |
| Flash settlement | Positive deltas mint claims; negative deltas burn claims before raw payment; raw payment refused while another contract's sync is pending; verify settlement amount | Real PoolManager, router checks hook deltas before paying swap input, fresh manager with zero ETH, both swap directions and amount modes, prepaying router through a rebalance |
| Emergency | Owner sets terminal mode; remove whole position; redeem all claims; owner receives no funds | Empty and funded vaults, fee and claim redemption, external LP fee collection still works |
| Emergency exit | Public entry burns only caller shares and pays proportional raw balances; no manager dependency | Two holders, partial/alternate recipient, double exit refusal, rejecting and reentrant ETH recipients, unavailable manager |

The handler-based invariant suite mixes deposits, withdrawals, swaps, donations, share transfers, elapsed time and emergencies. It checks raw token conservation across all participants, exact share conservation, position-liquidity consistency, valid tick grids and circular indexes, zero outstanding flash deltas and a locked manager after each transaction. Emergency mode additionally implies zero vault liquidity and claims. Every completed randomized sequence is followed by both holders' full emergency exits.

Arithmetic review covered the full usable tick domain, signed mean and negative grid rounding, zero volatility, integer square-root floors, strict 1.5-sigma comparisons, fee-growth wrapping, amount-to-liquidity overflow near extreme prices, and per-tick capacity shared with unrelated LPs. Liquidity sizing tests independently recompute rounded-up token costs to check that no budget is exceeded.

## Economic and operational limits

1. **Manipulable execution feed.** An attacker can change all eight observations through swaps, including within one block. Narrow ranges selected from it are exposed to MEV and adverse selection. The requested cooldown and statistics do not prevent this. The implementation does not silently add a different oracle, sample cadence or keeper permission.
2. **The balancing trade is a visible market order.** Each cycle sells the surplus side in the vault's own pool, paying the 1.25% LP fee to other LPs and up to the price impact allowed by the band edge and the 300-tick cap. A pending cycle can be read from chain state and sandwiched within that limit; the cap bounds the loss per cycle, and the 30-minute cooldown bounds the frequency. In a pool too thin to fill within the cap, inventory stays partly idle for several cycles. Idle raw dust and ERC-6909 claims remain shareholder assets, fully redeemable, earning no fees while idle.
3. **LP economics.** Fees do not guarantee profit. Price movement, impermanent loss, adversarial swaps, rounding and transaction costs can reduce returns. LP fee proceeds only arise from the vault's own LP position; factory LP fees remain the factory's.
4. **Minimum-share residue.** The initial 1,000 share units are permanently locked in the hook. Their portion of assets remains after all external holders withdraw. Minimum output bounds are still required; the lock is not a substitute for slippage protection.
5. **Emergency depends on the manager during activation.** If the manager or pair token already refuses asset transfers, activation can revert atomically. Once activation succeeds, exits need only the raw tokens and do not call the manager. Native recipients can choose an alternative address if they reject ETH.
6. **Automatic callbacks consume gas and are atomic.** An unexpected failure during a triggered rebalance reverts its enclosing swap. The code handles unavailable raw input balances and exhausted per-tick capacity, but a broken token or manager remains a liveness dependency. Rebalancing does not have a catch-and-ignore path that could conceal incomplete accounting.

Before release, an independent reviewer should assess these economic assumptions against the intended capital scale and traffic. The deployment operator should rehearse on the actual manager and factory, inspect all encoded parameters, confirm WETH/native pairing and Cancun support, and establish monitoring and an emergency operator. These are release responsibilities, not work represented as completed by the local test results.
