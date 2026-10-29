// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SigmaVault} from "src/SigmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SigmaVaultTest is Fixture {
    SigmaVault internal vToken;

    function setUp() public {
        _setup(false);
        vToken = hook.vault();
        _deposit(alice, 10 ether, 10 ether);
        _deposit(bob, 10 ether, 10 ether);
        vm.prank(alice);
        hook.approve(address(vToken), type(uint256).max);
        vm.prank(bob);
        hook.approve(address(vToken), type(uint256).max);
    }

    function test_canonicalWrapperIsOZ4626WithOneRealERC20Asset() public view {
        IERC4626 standard = IERC4626(address(vToken));
        assertEq(standard.asset(), address(hook));
        assertEq(standard.totalAssets(), 0);
        assertEq(vToken.symbol(), "svSHK");
        assertEq(vToken.decimals(), 18);
        assertEq(standard.convertToShares(1 ether), 1 ether);
        assertEq(standard.convertToAssets(1 ether), 1 ether);
        assertEq(standard.maxDeposit(alice), type(uint256).max);
        assertEq(standard.maxMint(alice), type(uint256).max);
        assertEq(standard.maxWithdraw(alice), 0);
        assertEq(standard.maxRedeem(alice), 0);
        assertLe(address(vToken).code.length, 24_576);
    }

    function test_allFourEntrypointsMatchPreviewsAndAssetFlows() public {
        uint256 assets = 1 ether;
        uint256 preview = vToken.previewDeposit(assets);
        uint256 before = hook.balanceOf(alice);
        vm.prank(alice);
        uint256 shares = vToken.deposit(assets, alice);
        assertEq(shares, preview);
        assertEq(before - hook.balanceOf(alice), assets);
        assertEq(vToken.totalAssets(), assets);
        uint256 cost = vToken.previewMint(2 ether);
        vm.prank(bob);
        assertEq(vToken.mint(2 ether, bob), cost);
        assertEq(vToken.balanceOf(bob), 2 ether);
        uint256 burn = vToken.previewWithdraw(0.25 ether);
        before = hook.balanceOf(bob);
        vm.prank(alice);
        assertEq(vToken.withdraw(0.25 ether, bob, alice), burn);
        assertEq(hook.balanceOf(bob) - before, 0.25 ether);
        uint256 proceeds = vToken.previewRedeem(vToken.balanceOf(alice));
        uint256 held = vToken.balanceOf(alice);
        before = hook.balanceOf(alice);
        vm.prank(alice);
        assertEq(vToken.redeem(held, alice, alice), proceeds);
        assertEq(hook.balanceOf(alice) - before, proceeds);
        assertEq(vToken.balanceOf(alice), 0);
    }

    function test_delegatedRedemptionSpendsShareAllowanceAndCannotSteal() public {
        vm.prank(alice);
        uint256 shares = vToken.deposit(2 ether, alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, shares));
        vToken.redeem(shares, bob, alice);
        vm.prank(alice);
        vToken.approve(bob, shares / 2);
        vm.prank(bob);
        vToken.redeem(shares / 2, bob, alice);
        assertEq(vToken.allowance(alice, bob), 0);
        assertEq(vToken.balanceOf(alice), shares / 2);
        vm.prank(bob);
        vm.expectRevert();
        vToken.withdraw(1, bob, alice);
    }

    function test_tradableVTokenOwnsUnderlyingNetFeesAndIdleDonations() public {
        uint256 assets = hook.balanceOf(alice);
        vm.prank(alice);
        uint256 shares = vToken.deposit(assets, alice);
        (uint256 before0, uint256 before1) = vToken.underlyingAssets(shares);
        router.donate(key, 2 ether, 4 ether);
        vm.prank(bob);
        token.transfer(address(hook), 1 ether);
        (uint256 after0, uint256 after1) = vToken.underlyingAssets(shares);
        assertGt(after0, before0);
        assertGt(after1, before1);
        // Yield accrues inside the receipt, so the ERC-4626 balance remains receipt-denominated.
        assertEq(vToken.totalAssets(), assets);
        vm.prank(alice);
        vToken.transfer(bob, shares);
        vm.prank(bob);
        uint256 receipts = vToken.redeem(shares, bob, bob);
        vm.prank(bob);
        (uint256 paid0, uint256 paid1) = hook.withdraw(receipts, 0, 0, bob, block.timestamp);
        assertApproxEqAbs(paid0, after0, 3);
        assertApproxEqAbs(paid1, after1, 3);
    }

    function test_receiptAndVTokenEmergencyExitNeedsNoManager() public {
        uint256 receipts = hook.balanceOf(alice);
        vm.prank(alice);
        uint256 shares = vToken.deposit(receipts, alice);
        vm.prank(owner);
        hook.activateEmergencyMode();
        vm.etch(address(manager), hex"60006000fd");
        (uint256 amount0, uint256 amount1) = vToken.underlyingAssets(shares);
        assertGt(amount0 + amount1, 0);
        vm.prank(alice);
        vToken.redeem(shares, alice, alice);
        vm.prank(alice);
        hook.emergencyWithdraw();
        assertEq(vToken.balanceOf(alice), 0);
        assertEq(hook.balanceOf(alice), 0);
    }

    function test_donationInflationCannotSilentlyMintZeroShares() public {
        vm.prank(alice);
        vToken.deposit(1, alice);
        vm.prank(alice);
        hook.transfer(address(vToken), 1 ether);
        assertEq(vToken.previewDeposit(1), 0);
        uint256 before = hook.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(SigmaVault.ZeroShares.selector);
        vToken.deposit(1, bob);
        assertEq(hook.balanceOf(bob), before);
    }

    function testFuzz_previewsRoundInFavorOfVault(uint64 assetsSeed, uint64 donationSeed) public {
        uint256 assets = bound(assetsSeed, 1, 10 ether);
        uint256 donation = bound(donationSeed, 0, 10 ether);
        vm.prank(alice);
        vToken.deposit(1 ether, alice);
        vm.prank(alice);
        hook.transfer(address(vToken), donation);
        uint256 floorShares = vToken.convertToShares(assets);
        assertEq(vToken.previewDeposit(assets), floorShares);
        assertGe(vToken.previewWithdraw(assets), floorShares);
        assertLe(vToken.previewWithdraw(assets) - floorShares, 1);
        if (floorShares == 0) return;
        uint256 before = hook.balanceOf(bob);
        vm.prank(bob);
        uint256 shares = vToken.deposit(assets, bob);
        assertEq(shares, floorShares);
        assertLe(vToken.previewRedeem(shares), assets);
        uint256 needed = vToken.previewMint(shares);
        assertGe(needed, vToken.convertToAssets(shares));
        vm.prank(bob);
        vToken.redeem(shares, bob, bob);
        assertLe(hook.balanceOf(bob), before);
        assertEq(vToken.totalAssets(), hook.balanceOf(address(vToken)));
    }
}
