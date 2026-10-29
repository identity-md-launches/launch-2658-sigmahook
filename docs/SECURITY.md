# Security review record — Sprint 2

Implementation self-review against the pinned security, address and L2 inputs. This is not an independent audit, fork test, on-chain verification, or a claim that production deployment is authorized. The existing token and immutable deployed hook are unchanged on chain.

## Fund boundaries

- The immutable manager and bound pool are the only strategy venue. Callback identity and the outstanding-unlock latch are checked. Own hook swaps skip callbacks under the vendored v4 dispatch rules. All operations finish with zero manager currency deltas.
- The actual manager liquidity delta determines first-deposit spending and shares. Only caller-owned tokens are pulled. Preview and execution use the same refreshed range. Refunds happen inside the initial unlock. Donations cannot be silently included in a depositor's invested budget.
- LP assets exclude reserved buyback and keeper proceeds, including uncollected fee allocations. `feesAccrued` is separated from principal; `callerDelta` includes fees already. Reserve debits use actual buyback inputs and outputs. Fees harvested by deposits cannot be paid to those depositors or reinvested twice.
- Native balances have a separate accounting ledger. Only pool settlement native receipts enter that ledger. The owner's rescue is bounded by surplus over the ledger. Forced ETH cannot inflate LP quotes or make an LP withdrawal available to the owner.
- Buyback proceeds enter a zero-address transfer or an immutable lock with no callable withdrawal logic. The current token requires the lock. Locking is not total-supply burning. No recipient supplied by a keeper or owner can redirect it.
- The ERC-4626 wrapper holds only genuine basket receipts and has no admin. It inherits OpenZeppelin rounding, previews, limits and delegated allowance behavior. It adds a zero-share positive-deposit refusal. Its canonical asset is the hook's simple ERC-20 ledger, without token callbacks; arbitrary deployments over malicious replacement assets are outside the canonical architecture.

## Adversarial paths checked

| Path | Expected result |
| --- | --- |
| Wrong pool / wrong manager / unexpected unlock | Revert before funds move |
| Keeper too early / at or inside deviation threshold / no external shares / emergency | Revert with explicit gating error |
| Price jump, shallow or empty active liquidity | Nonzero investment or explicit persistent, redeemable pending inventory |
| Failed keeper payout or reentry | Whole rebalance rolls back; reentry is blocked |
| Zero-address-rejecting launch token | Buyback proceeds reach the permanent lock; rebalance remains live |
| Fees collected before keeper call | 20% and 1% remain reserved, excluded from LP pricing and investment |
| First deposit after price moves, asymmetric budgets, native refunds | Preview matches actual costs; only consumed assets leave depositor |
| Taxed/callback pair token | Exact-pull validation and reentrancy protection reject unsafe behavior |
| ERC-4626 delegated exit without allowance / zero-share inflation | Revert atomically |
| Forced ETH with funded native position or emergency vault | Rescue transfers only unaccounted surplus |
| Emergency after keeper cycles | LP assets become raw; remaining fee reservations are released; holder exits do not need manager |

Meaningful unit, fuzz and stateful accounting tests use the actual vendored manager and the assignment's specified seed. State-machine tests check custody conservation, receipt conservation, fee liabilities, position accounting, sample history, no outstanding flash debts and full emergency exits. Tests are independent of network, environment values and order. See the accompanying test README for coverage.

## Limits and release responsibilities

1. The eight execution ticks can be manipulated in one block. The requested timestamp/deviation gates and band price limits are not a trusted price oracle. Deeper routes remove starvation at the expense of larger permitted price movement. No unverified router/TWAP is configured implicitly.
2. The vault supports ordinary fixed-balance, untaxed native/ERC-20 assets. Token censorship, rebasing, upgrades or dishonest transfer returns can break liveness/accounting; exact pulls do not make a malicious token trustworthy.
3. If there is no counterparty liquidity or per-tick capacity, capital can remain idle. Pending investment can be retried without paying another keeper bounty. Unfilled buyback inputs remain liabilities until a later eligible rebalance; the owner cannot take them via ETH rescue. Emergency cancels remaining reservations back to shareholders.
4. A rejecting keeper only fails its own transaction. External swaps perform no fee distribution or investment work. Manager/token failure can still prevent emergency activation; successful activation removes that manager dependency for exits.
5. The initial 1,000 locked basket units and ERC-4626 virtual share units are permanent rounding/inflation defenses, not substitutes for user slippage checks. Tiny donations/rounding may remain after the last external holder exits.
6. The old hook is immutable. This source release requires a separately reviewed deployment and voluntary liquidity migration using the existing token. The pinned chain advertises an extended swap ABI; the protected local dependency is upstream v4. Its compatibility must be established before deploying. This is not proven by local unit tests.

No Slither, Mythril, formal proof, independent review, or actual-chain deployment rehearsal is represented as completed here. An independent reviewer and the deployment operator must resolve the economic and manager-ABI risks before accepting public funds.
