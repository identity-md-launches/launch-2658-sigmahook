// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Population statistics over eight execution ticks, with explicit integer rounding.
library BandMath {
    function statistics(int24[8] memory ticks) internal pure returns (int24 mean, uint256 sigma) {
        int256 sum = 0;
        for (uint256 i; i < 8; ++i) {
            sum += ticks[i];
        }
        // Solidity's signed division truncates towards zero.
        mean = int24(sum / 8);
        uint256 squared = 0;
        for (uint256 i; i < 8; ++i) {
            int256 distance = int256(ticks[i]) - mean;
            squared += uint256(distance * distance);
        }
        sigma = Math.sqrt(squared / 8);
    }

    function deviates(int24 tick, int24 mean, uint256 sigma) internal pure returns (bool) {
        int256 distance = int256(tick) - mean;
        uint256 absolute = uint256(distance < 0 ? -distance : distance);
        // Strictly greater than 1.5 sigma, without truncating the half tick.
        return 2 * absolute > 3 * sigma;
    }

    function bands(int24 mean, uint256 sigma, int24 spacing) internal pure returns (int24 lower, int24 upper) {
        int256 width = int256(3 * sigma);
        int256 lo = floor(int256(mean) - width, spacing);
        int256 hi = -floor(-int256(mean) - width, spacing);
        // A zero-volatility feed still needs a non-empty position.
        if (lo == hi) {
            lo -= spacing;
            hi += spacing;
        }
        int256 minTick = TickMath.minUsableTick(spacing);
        int256 maxTick = TickMath.maxUsableTick(spacing);
        if (lo < minTick) lo = minTick;
        if (hi > maxTick) hi = maxTick;
        if (lo >= hi) {
            if (lo >= maxTick) lo = maxTick - spacing;
            else hi = minTick + spacing;
        }
        lower = int24(lo);
        upper = int24(hi);
    }

    function floor(int256 tick, int24 spacing) internal pure returns (int256 result) {
        result = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --result;
        result *= spacing;
    }
}
