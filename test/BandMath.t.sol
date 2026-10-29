// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BandMath} from "../src/libraries/BandMath.sol";
import {VaultMath} from "../src/libraries/VaultMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract BandMathTest is Test {
    function test_knownPopulationStatistics() public pure {
        int24[8] memory samples = [int24(-4), -3, -2, -1, 1, 2, 3, 4];
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, 0);
        assertEq(sigma, 2); // floor(sqrt(floor(60/8)))
        samples = [int24(0), 0, 0, 0, 0, 0, 0, 800];
        (mean, sigma) = BandMath.statistics(samples);
        assertEq(mean, 100);
        assertEq(sigma, 264); // floor(sqrt(70,000))
        (int24 lower, int24 upper) = BandMath.bands(mean, sigma, 60);
        assertEq(lower, -720);
        assertEq(upper, 900);
    }

    function test_negativeMeanTruncatesTowardsZero() public pure {
        int24[8] memory samples = [int24(-1), -1, -1, -1, -1, -1, -1, 0];
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, 0);
        assertEq(sigma, 0);
        (int24 lower, int24 upper) = BandMath.bands(-61, 0, 60);
        assertEq(lower, -120);
        assertEq(upper, -60);
    }

    function test_strictTriggerAndHalfIntegerThreshold() public pure {
        assertFalse(BandMath.deviates(3, 0, 2));
        assertTrue(BandMath.deviates(4, 0, 2));
        assertFalse(BandMath.deviates(-3, 0, 2));
        assertTrue(BandMath.deviates(-4, 0, 2));
        assertFalse(BandMath.deviates(4, 0, 3));
        assertTrue(BandMath.deviates(5, 0, 3));
        assertFalse(BandMath.deviates(-4, 0, 3));
        assertTrue(BandMath.deviates(-5, 0, 3));
        assertFalse(BandMath.deviates(0, 0, 0));
        assertTrue(BandMath.deviates(1, 0, 0));
    }

    function test_extremeTicksStayWithinUsableGrid() public pure {
        (int24 lower, int24 upper) = BandMath.bands(TickMath.MIN_TICK, 0, 60);
        assertEq(lower, -887220);
        assertEq(upper, -887160);
        (lower, upper) = BandMath.bands(TickMath.MAX_TICK, 0, 60);
        assertEq(lower, 887160);
        assertEq(upper, 887220);
        int24[8] memory samples = [int24(-887272), 887272, -887272, 887272, -887272, 887272, -887272, 887272];
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, 0);
        assertEq(sigma, 887272);
        (lower, upper) = BandMath.bands(mean, sigma, 60);
        assertEq(lower, -887220);
        assertEq(upper, 887220);
    }

    function testFuzz_statisticsMatchIndependentIntegerReference(int24[8] memory samples, uint16 spacingSeed)
        public
        pure
    {
        int256 sum;
        int256 squares;
        for (uint256 i; i < 8; ++i) {
            samples[i] = int24(bound(samples[i], TickMath.MIN_TICK, TickMath.MAX_TICK));
            sum += samples[i];
            squares += int256(samples[i]) * samples[i];
        }
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        int256 referenceMean = sum / 8;
        uint256 variance = uint256((squares - 2 * referenceMean * sum + 8 * referenceMean * referenceMean) / 8);
        assertEq(mean, referenceMean);
        assertLe(sigma * sigma, variance);
        assertGt((sigma + 1) * (sigma + 1), variance);
        int24 spacing = int24(int256(bound(spacingSeed, 1, 32767)));
        (int24 lower, int24 upper) = BandMath.bands(mean, sigma, spacing);
        assertLt(lower, upper);
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertGe(lower, TickMath.minUsableTick(spacing));
        assertLe(upper, TickMath.maxUsableTick(spacing));
    }

    function testFuzz_liquiditySizingNeverOverspends(
        int24 lowerSeed,
        int24 upperSeed,
        int24 currentSeed,
        uint128 budget0,
        uint128 budget1,
        uint128 cap
    ) public pure {
        int24 lower = int24(bound(lowerSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 upper = int24(bound(upperSeed, lower + 1, TickMath.MAX_TICK));
        int24 current = int24(bound(currentSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint160 price = TickMath.getSqrtPriceAtTick(current);
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint128 l = VaultMath.liquidityForAmounts(price, lo, hi, budget0, budget1, cap);
        (uint256 need0, uint256 need1) = VaultMath.amounts(price, lo, hi, l, true);
        assertLe(l, cap);
        assertLe(need0, budget0);
        assertLe(need1, budget1);
    }

    function test_sizingOneSqrtUnitFromUpperAndVeryLowTicks() public pure {
        uint160 lo = TickMath.getSqrtPriceAtTick(887100);
        uint160 hi = TickMath.getSqrtPriceAtTick(887220);
        uint128 l = VaultMath.liquidityForAmounts(hi - 1, lo, hi, type(uint128).max, 1e27, 1e30);
        (uint256 a0, uint256 a1) = VaultMath.amounts(hi - 1, lo, hi, l, true);
        assertLe(a0, type(uint128).max);
        assertLe(a1, 1e27);
        lo = TickMath.getSqrtPriceAtTick(-887220);
        hi = TickMath.getSqrtPriceAtTick(-887100);
        l = VaultMath.liquidityForAmounts(lo, lo, hi, 1e27, 0, 1e30);
        assertGt(l, 0);
        (a0, a1) = VaultMath.amounts(lo, lo, hi, l, true);
        assertLe(a0, 1e27);
        assertEq(a1, 0);
    }
}
