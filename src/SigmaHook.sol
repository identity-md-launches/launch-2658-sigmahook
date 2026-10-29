// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {VaultMath} from "./libraries/VaultMath.sol";

/// @notice Single-pool vault with execution-tick SMA bands and automatic fee compounding.
/// @dev Shares represent only this hook's position and idle assets, never other LP positions.
contract SigmaHook is BaseHook, ERC20, Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error NotInitialized();
    error AlreadyInitialized();
    error InvalidPool();
    error NotFactory();
    error EmergencyActive();
    error EmergencyInactive();
    error InvalidAmount();
    error Slippage();
    error Expired();
    error UnexpectedNativeValue();
    error UnsupportedToken();
    error UnexpectedUnlock();
    error OwnershipRequired();
    error InsufficientClaims();

    uint256 public constant REBALANCE_INTERVAL = 30 minutes;
    uint256 public constant MINIMUM_SHARES = 1_000;
    /// @notice A rebalance sells surplus inventory only when it exceeds this share of vault value.
    uint256 public constant REBALANCE_SWAP_DEADBAND_BPS = 100;
    /// @notice A balancing trade stops at the band edge, and never more than this many ticks away.
    int24 public constant REBALANCE_SWAP_MAX_TICKS = 300;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    bytes32 public constant POSITION_SALT = keccak256("SigmaHook.vault");

    address public immutable launchToken;
    address public immutable factory;
    PoolKey private _key;
    PoolId public poolId;
    bool public initialized;
    bool public emergencyMode;
    int24[8] public ticks;
    uint8 public nextSample;
    uint256 public lastRebalance;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    bool private _expectUnlock;

    enum Action {
        Harvest,
        Invest,
        Withdraw,
        Emergency
    }

    event PoolBound(PoolId indexed id, address currency0, address currency1, int24 launchTick);
    event SampleRecorded(uint8 indexed index, int24 tick, int24 mean, uint256 sigma);
    event Rebalanced(int24 lower, int24 upper, uint128 oldLiquidity, uint128 newLiquidity);
    event BandRefreshed(int24 lower, int24 upper);
    event InventoryBalanced(bool zeroForOne, uint256 amountIn, int128 delta0, int128 delta1);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event Deposited(address indexed caller, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed caller, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event EmergencyActivated(uint256 amount0, uint256 amount1);

    constructor(IPoolManager manager_, address owner_, address launchToken_, address factory_)
        BaseHook(manager_)
        ERC20("SigmaHook Vault Share", "svSHK")
        Ownable(owner_)
    {
        if (address(manager_) == address(0) || launchToken_ == address(0) || factory_ == address(0)) {
            revert InvalidAddress();
        }
        launchToken = launchToken_;
        factory = factory_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.afterSwap = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    /// @notice Whole-tick view of the feed: mean rounded to nearest, sigma floored.
    function statistics() public view returns (int24 mean, uint256 sigma) {
        return BandMath.statistics(ticks);
    }

    /// @notice The exact feed moments in eighths of a tick: sum = 8 × mean, sigma8 = floor(8 × sigma).
    function moments() public view returns (int256 sum, uint256 sigma8) {
        return BandMath.moments(ticks);
    }

    function proposedBands() external view returns (int24 lower, int24 upper) {
        _requireInitialized();
        (int256 sum, uint256 sigma8) = moments();
        return BandMath.bands(sum, sigma8, _key.tickSpacing);
    }

    /// @notice Principal, uncollected fees, raw dust, and ERC-6909 claims in pool currency order.
    /// @dev Principal rounds down here; deposit pricing rounds it up to protect existing holders.
    function totalAssets() external view returns (uint256 amount0, uint256 amount1) {
        _requireInitialized();
        return _assets(false);
    }

    /// @notice Quote maximum shares for the supplied budgets, including uncollected fees.
    /// @dev This is a spot-state quote. Set minShares and a deadline when submitting a deposit.
    function previewDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        _requireLive();
        return _quoteDeposit(amount0Max, amount1Max, 0);
    }

    /// @notice Deposit a proportional basket. Unused ERC-20 budgets are never pulled, on the first
    /// deposit included: only what the minted liquidity costs leaves the caller.
    /// @dev For native currency0 send exactly amount0Max; unused ETH is refunded to the caller.
    /// While the vault holds no position the band is refreshed from the feed before quoting, so a
    /// first deposit after the price has moved invests around the current price.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        _requireLive();
        _checkReceiver(receiver);
        if (block.timestamp > deadline) revert Expired();
        if (minShares == 0) revert InvalidAmount();
        if (msg.value != (_key.currency0.isAddressZero() ? amount0Max : 0)) revert UnexpectedNativeValue();

        // Existing holders own all fees earned before the deposit.
        if (liquidity != 0) {
            _unlock(Action.Harvest, 0, 0);
        } else {
            (int256 sum, uint256 sigma8) = moments();
            (tickLower, tickUpper) = BandMath.bands(sum, sigma8, _key.tickSpacing);
            emit BandRefreshed(tickLower, tickUpper);
        }
        (shares, amount0, amount1) = _quoteDeposit(amount0Max, amount1Max, msg.value);
        if (shares == 0 || shares < minShares) revert Slippage();
        if (totalSupply() == 0) _mint(address(this), MINIMUM_SHARES);
        _mint(receiver, shares);

        // Tokens are pulled exclusively from the entry point's msg.sender.
        _pull(_key.currency0, amount0);
        _pull(_key.currency1, amount1);
        if (_key.currency0.isAddressZero() && msg.value > amount0) {
            _key.currency0.transfer(msg.sender, msg.value - amount0);
        }
        _unlock(Action.Invest, 0, 0);
        emit Deposited(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Burn the caller's shares for principal, fees, and idle assets at any time while live.
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _requireLive();
        _checkReceiver(receiver);
        if (block.timestamp > deadline) revert Expired();
        if (shares == 0) revert InvalidAmount();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        (amount0, amount1) = abi.decode(_unlock(Action.Withdraw, shares, supply), (uint256, uint256));
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
        _pay(receiver, amount0, amount1);
        emit Withdrawn(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Irreversibly exit the vault's position and redeem every claim into raw assets.
    /// @dev Other LP positions and swaps remain usable. The owner receives no assets.
    function activateEmergencyMode() external onlyOwner nonReentrant {
        _requireLive();
        emergencyMode = true;
        _unlock(Action.Emergency, 0, 0);
        emit EmergencyActivated(_key.currency0.balanceOfSelf(), _key.currency1.balanceOfSelf());
    }

    /// @notice Immediately redeem all caller-owned shares, without calling the PoolManager.
    function emergencyWithdraw() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _emergencyWithdraw(balanceOf(msg.sender), msg.sender);
    }

    /// @notice Partial redemption or an alternative receiving wallet, including for contracts rejecting ETH.
    function emergencyWithdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        return _emergencyWithdraw(shares, receiver);
    }

    /// @dev Keep an accountable emergency owner; transfers use Ownable2Step.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        nonReentrant
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        if (
            address(key.hooks) != address(this) || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING
                || (Currency.unwrap(key.currency0) != launchToken && Currency.unwrap(key.currency1) != launchToken)
        ) revert InvalidPool();
        _checkCurrency(key.currency0);
        _checkCurrency(key.currency1);
        _key = key;
        poolId = key.toId();
        initialized = true;
        for (uint256 i; i < 8; ++i) {
            ticks[i] = tick;
        }
        (tickLower, tickUpper) = BandMath.bands(int256(tick) * BandMath.SAMPLES, 0, key.tickSpacing);
        lastRebalance = block.timestamp;
        emit PoolBound(poolId, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), tick);
        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        nonReentrant
        returns (bytes4, int128)
    {
        _requireInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint8 index = nextSample;
        ticks[index] = tick;
        nextSample = (index + 1) % 8;
        (int256 sum, uint256 sigma8) = moments();
        {
            (int24 mean, uint256 sigma) = BandMath.rounded(sum, sigma8);
            emit SampleRecorded(index, tick, mean, sigma);
        }
        // Only external holders justify a cycle: the locked minimum shares alone never trigger one.
        if (
            !emergencyMode && totalSupply() > MINIMUM_SHARES && block.timestamp >= lastRebalance + REBALANCE_INTERVAL
                && BandMath.deviates(tick, sum, sigma8)
        ) {
            // The manager is already unlocked by the swap router. Never nest unlock().
            lastRebalance = block.timestamp;
            // A router that synced an ERC-20 before its swap is mid-payment: a second sync would
            // absorb its transfer and reset its settlement, so this cycle pays from claims only and
            // leaves raw dust for a later one.
            bool useRaw = poolManager.getSyncedCurrency().isAddressZero();
            uint128 oldLiquidity = liquidity;
            if (oldLiquidity != 0) _changeLiquidity(-int256(uint256(oldLiquidity)), useRaw);
            (tickLower, tickUpper) = BandMath.bands(sum, sigma8, key.tickSpacing);
            _balanceInventory(useRaw);
            _invest(useRaw);
            emit Rebalanced(tickLower, tickUpper, oldLiquidity, liquidity);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory result) {
        if (!_expectUnlock) revert UnexpectedUnlock();
        _expectUnlock = false;
        (Action action, uint256 shares, uint256 supply) = abi.decode(data, (Action, uint256, uint256));
        if (action == Action.Harvest) {
            _harvest();
        } else if (action == Action.Invest) {
            _invest(true);
        } else if (action == Action.Withdraw) {
            _harvest();
            uint256 amount0 = FullMath.mulDiv(_idle(_key.currency0), shares, supply);
            uint256 amount1 = FullMath.mulDiv(_idle(_key.currency1), shares, supply);
            uint128 removed = uint128(FullMath.mulDiv(liquidity, shares, supply));
            if (removed != 0) {
                BalanceDelta delta = _changeLiquidity(-int256(uint256(removed)), true);
                amount0 += uint128(delta.amount0());
                amount1 += uint128(delta.amount1());
            }
            _makeRaw(_key.currency0, amount0);
            _makeRaw(_key.currency1, amount1);
            result = abi.encode(amount0, amount1);
        } else {
            if (liquidity != 0) _changeLiquidity(-int256(uint256(liquidity)), true);
            _makeRaw(_key.currency0, _idle(_key.currency0));
            _makeRaw(_key.currency1, _idle(_key.currency1));
        }
    }

    function _unlock(Action action, uint256 shares, uint256 supply) private returns (bytes memory) {
        _expectUnlock = true;
        return poolManager.unlock(abi.encode(action, shares, supply));
    }

    function _harvest() private {
        if (liquidity != 0) _changeLiquidity(0, true);
    }

    function _changeLiquidity(int256 change, bool useRaw) private returns (BalanceDelta delta) {
        if (change < 0) liquidity -= uint128(uint256(-change));
        else liquidity += uint128(uint256(change));
        BalanceDelta fees;
        (delta, fees) =
            poolManager.modifyLiquidity(_key, ModifyLiquidityParams(tickLower, tickUpper, change, POSITION_SALT), "");
        // callerDelta ALREADY includes fees; never add feesAccrued a second time.
        _settle(_key.currency0, delta.amount0(), useRaw);
        _settle(_key.currency1, delta.amount1(), useRaw);
        if (fees.amount0() != 0 || fees.amount1() != 0) {
            emit FeesCollected(uint128(fees.amount0()), uint128(fees.amount1()));
        }
    }

    function _invest(bool useRaw) private {
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        uint128 added = VaultMath.liquidityForAmounts(
            price,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _budget(_key.currency0, useRaw),
            _budget(_key.currency1, useRaw),
            _capacity()
        );
        if (added != 0) _changeLiquidity(int256(uint256(added)), useRaw);
    }

    /// @dev Sell the surplus side into the pool so the inventory matches the band's ratio at the
    /// current price (see VaultMath.rebalanceTrade). The price limit is the band edge the trade
    /// moves towards, capped at REBALANCE_SWAP_MAX_TICKS, so the vault never trades outside the
    /// range it is about to supply; whatever stays unsold waits for the next cycle.
    function _balanceInventory(bool useRaw) private {
        // With nothing to trade against a swap would only displace the price.
        if (poolManager.getLiquidity(poolId) == 0) return;
        (uint160 price, int24 tick,,) = poolManager.getSlot0(poolId);
        (bool zeroForOne, uint256 amountIn) = VaultMath.rebalanceTrade(
            price,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _budget(_key.currency0, useRaw),
            _budget(_key.currency1, useRaw),
            REBALANCE_SWAP_DEADBAND_BPS
        );
        if (amountIn == 0) return;
        uint160 limit = VaultMath.tradeLimit(zeroForOne, tick, tickLower, tickUpper, REBALANCE_SWAP_MAX_TICKS);
        if (zeroForOne ? limit >= price : limit <= price) return;
        // The manager skips this hook's own callbacks for a swap it sends itself.
        BalanceDelta delta = poolManager.swap(_key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        _settle(_key.currency0, delta.amount0(), useRaw);
        _settle(_key.currency1, delta.amount1(), useRaw);
        emit InventoryBalanced(zeroForOne, amountIn, delta.amount0(), delta.amount1());
    }

    /// @dev Spendable inventory: claims, plus raw balance when the hook may settle it, bounded to int128.
    function _budget(Currency currency, bool useRaw) private view returns (uint256 amount) {
        amount = poolManager.balanceOf(address(this), currency.toId());
        if (useRaw) amount += currency.balanceOfSelf();
        return Math.min(amount, uint256(uint128(type(int128).max)));
    }

    /// @dev Match v4's per-tick cap, including other LPs sharing either boundary.
    function _capacity() private view returns (uint128) {
        int256 minIndex = BandMath.floor(TickMath.MIN_TICK, _key.tickSpacing) / _key.tickSpacing;
        int256 maxIndex = int256(TickMath.MAX_TICK) / _key.tickSpacing;
        uint128 maxPerTick = uint128(type(uint128).max / uint256(maxIndex - minIndex + 1));
        (uint128 grossLower,) = poolManager.getTickLiquidity(poolId, tickLower);
        (uint128 grossUpper,) = poolManager.getTickLiquidity(poolId, tickUpper);
        uint128 gross = grossLower > grossUpper ? grossLower : grossUpper;
        return gross >= maxPerTick ? 0 : maxPerTick - gross;
    }

    /// @dev Positive deltas become claims so afterSwap never takes unsettled router inputs.
    /// Negative deltas consume claims first and then, when `useRaw`, settle from the raw balance.
    function _settle(Currency currency, int128 delta, bool useRaw) private {
        if (delta > 0) {
            poolManager.mint(address(this), currency.toId(), uint128(delta));
        } else if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            uint256 claims = Math.min(debt, poolManager.balanceOf(address(this), currency.toId()));
            if (claims != 0) poolManager.burn(address(this), currency.toId(), claims);
            debt -= claims;
            if (debt != 0) {
                if (!useRaw) revert InsufficientClaims();
                poolManager.sync(currency);
                uint256 paid;
                if (currency.isAddressZero()) {
                    paid = poolManager.settle{value: debt}();
                } else {
                    currency.transfer(address(poolManager), debt);
                    paid = poolManager.settle();
                }
                if (paid != debt) revert UnsupportedToken();
            }
        }
    }

    function _makeRaw(Currency currency, uint256 amount) private {
        uint256 raw = currency.balanceOfSelf();
        if (amount > raw) {
            uint256 redeem = amount - raw;
            poolManager.burn(address(this), currency.toId(), redeem);
            poolManager.take(currency, address(this), redeem);
        }
    }

    function _idle(Currency currency) private view returns (uint256) {
        return currency.balanceOfSelf() + poolManager.balanceOf(address(this), currency.toId());
    }

    function _assets(bool roundUp) private view returns (uint256 amount0, uint256 amount1) {
        amount0 = _idle(_key.currency0);
        amount1 = _idle(_key.currency1);
        if (liquidity != 0) {
            (uint160 price,,,) = poolManager.getSlot0(poolId);
            (uint256 principal0, uint256 principal1) = VaultMath.amounts(
                price,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity,
                roundUp
            );
            (, uint256 last0, uint256 last1) =
                poolManager.getPositionInfo(poolId, address(this), tickLower, tickUpper, POSITION_SALT);
            (uint256 growth0, uint256 growth1) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
            // Fee growth wraps modulo 2^256 in v4.
            unchecked {
                growth0 -= last0;
                growth1 -= last1;
            }
            amount0 += principal0 + FullMath.mulDiv(growth0, liquidity, 1 << 128);
            amount1 += principal1 + FullMath.mulDiv(growth1, liquidity, 1 << 128);
        }
    }

    function _quoteDeposit(uint256 max0, uint256 max1, uint256 incomingNative)
        private
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        // Bound input budgets, while allowing donations to remain in the asset accounting.
        if (max0 > uint128(type(int128).max) || max1 > uint128(type(int128).max)) revert InvalidAmount();
        uint256 supply = totalSupply();
        if (supply == 0) {
            (uint160 price,,,) = poolManager.getSlot0(poolId);
            uint128 initial = VaultMath.liquidityForAmounts(
                price,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                max0,
                max1,
                _capacity()
            );
            if (initial <= MINIMUM_SHARES) return (0, 0, 0);
            // Pull only what the minted liquidity costs, never the unused side of the budget.
            (amount0, amount1) = VaultMath.amounts(
                price, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), initial, true
            );
            return (initial - MINIMUM_SHARES, amount0, amount1);
        }
        (uint256 assets0, uint256 assets1) = _assets(true);
        assets0 -= incomingNative;
        if (assets0 == 0 && assets1 == 0) revert InvalidAmount();
        uint256 shares0 = assets0 == 0 ? type(uint256).max : FullMath.mulDiv(max0, supply, assets0);
        uint256 shares1 = assets1 == 0 ? type(uint256).max : FullMath.mulDiv(max1, supply, assets1);
        shares = Math.min(shares0, shares1);
        amount0 = Math.mulDiv(shares, assets0, supply, Math.Rounding.Ceil);
        amount1 = Math.mulDiv(shares, assets1, supply, Math.Rounding.Ceil);
    }

    function _pull(Currency currency, uint256 amount) private {
        if (amount == 0 || currency.isAddressZero()) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
    }

    function _emergencyWithdraw(uint256 shares, address receiver) private returns (uint256 amount0, uint256 amount1) {
        if (!emergencyMode) revert EmergencyInactive();
        _checkReceiver(receiver);
        if (shares == 0) revert InvalidAmount();
        uint256 supply = totalSupply();
        amount0 = FullMath.mulDiv(_key.currency0.balanceOfSelf(), shares, supply);
        amount1 = FullMath.mulDiv(_key.currency1.balanceOfSelf(), shares, supply);
        _burn(msg.sender, shares);
        _pay(receiver, amount0, amount1);
        emit Withdrawn(msg.sender, receiver, shares, amount0, amount1);
    }

    function _pay(address receiver, uint256 amount0, uint256 amount1) private {
        if (amount0 != 0) _key.currency0.transfer(receiver, amount0);
        if (amount1 != 0) _key.currency1.transfer(receiver, amount1);
    }

    function _checkCurrency(Currency currency) private view {
        if (!currency.isAddressZero() && Currency.unwrap(currency).code.length == 0) revert UnsupportedToken();
    }

    function _checkReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
    }

    function _requireInitialized() private view {
        if (!initialized) revert NotInitialized();
    }

    function _requireLive() private view {
        _requireInitialized();
        if (emergencyMode) revert EmergencyActive();
    }

    /// @dev Only the manager paying out native currency0 may send ETH here; stray ETH would be
    /// unaccounted on an ERC-20 pair and has no recovery path.
    receive() external payable {
        if (msg.sender != address(poolManager) || !initialized || !_key.currency0.isAddressZero()) {
            revert UnexpectedNativeValue();
        }
    }
}
