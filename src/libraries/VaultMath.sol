// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

library VaultMath {
    uint256 internal constant Q96 = 1 << 96;

    function amounts(uint160 price, uint160 lower, uint160 upper, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (price < upper) {
            amount0 = SqrtPriceMath.getAmount0Delta(price > lower ? price : lower, upper, liquidity, roundUp);
        }
        if (price > lower) {
            amount1 = SqrtPriceMath.getAmount1Delta(lower, price < upper ? price : upper, liquidity, roundUp);
        }
    }

    /// @dev Cap before narrowing to uint128. Testing the cap's cost also prevents mulDiv overflow
    /// when the current price is only one sqrt-price unit away from a boundary.
    function liquidityForAmounts(
        uint160 price,
        uint160 lower,
        uint160 upper,
        uint256 amount0,
        uint256 amount1,
        uint128 cap
    ) internal pure returns (uint128) {
        if (cap == 0) return 0;
        (uint256 need0, uint256 need1) = amounts(price, lower, upper, cap, true);
        uint256 result = cap;
        if (amount0 < need0) {
            uint160 a = price > lower ? price : lower;
            uint256 intermediate = FullMath.mulDiv(a, upper, Q96);
            uint256 l0;
            if (intermediate == 0) {
                // At very low ticks a*b < Q96; preserve the fraction instead of rounding to zero.
                l0 = FullMath.mulDiv(amount0, uint256(a) * upper, (uint256(upper) - a) * Q96);
            } else {
                l0 = FullMath.mulDiv(amount0, intermediate, uint256(upper) - a);
            }
            if (l0 < result) result = l0;
        }
        if (amount1 < need1) {
            uint256 l1 = FullMath.mulDiv(amount1, Q96, uint256(price < upper ? price : upper) - lower);
            if (l1 < result) result = l1;
        }
        return uint128(result);
    }
}
