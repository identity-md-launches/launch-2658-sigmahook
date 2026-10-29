// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ReenterReceiver {
    SigmaHook public immutable hook;
    bool public attempted;
    bool public succeeded;
    bytes4 public refusal;

    constructor(SigmaHook hook_) {
        hook = hook_;
    }

    function exit() external {
        hook.emergencyWithdraw();
    }

    receive() external payable {
        attempted = true;
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeWithSignature("emergencyWithdraw()"));
        succeeded = ok;
        refusal = bytes4(reason);
    }
}

contract RejectEth {
    function exit(SigmaHook hook, address receiver) external {
        hook.emergencyWithdraw(hook.balanceOf(address(this)), receiver);
    }
}

contract NativeVaultTest is Fixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setup(true);
    }

    function test_nativeDepositRefundAndOrdinaryExit() public {
        _deposit(alice, 10 ether, 10 ether);
        uint256 ethBefore = bob.balance;
        uint256 shares = _deposit(bob, 20 ether, 5 ether);
        assertApproxEqAbs(ethBefore - bob.balance, 5 ether, 1);
        vm.prank(bob);
        (uint256 nativePaid, uint256 tokenPaid) = hook.withdraw(shares, 0, 0, bob, block.timestamp);
        assertApproxEqAbs(nativePaid, 5 ether, 5);
        assertApproxEqAbs(tokenPaid, 5 ether, 5);
        vm.prank(alice);
        vm.expectRevert(SigmaHook.UnexpectedNativeValue.selector);
        hook.deposit{value: 1}(1 ether, 1 ether, 1, alice, block.timestamp);
    }

    function testFuzz_freshManagerRebalanceBeforeInputSettlement(bool exactOutput) public {
        // With no liquidity, v4 moves to the price limit with zero token delta.
        _moveTo(60);
        _deposit(alice, 0, 10 ether); // price is at the upper boundary: entirely token1.
        assertEq(address(manager).balance, 0);
        assertEq(address(hook).balance, 0);
        uint256 initialTime = hook.lastRebalance();
        vm.warp(initialTime + 30 minutes);
        router.swap(key, true, exactOutput ? int256(9 ether) : -int256(100 ether), TickMath.getSqrtPriceAtTick(-50));
        assertEq(hook.lastRebalance(), block.timestamp);
        assertTrue(router.hookDeltasWereZero());
        assertGt(address(manager).balance, 0); // router paid only after the callback completed.
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        assertGt(assets0 + assets1, 9 ether);
        _assertPositionMatches();
        vm.prank(owner);
        hook.activateEmergencyMode();
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        vm.prank(alice);
        hook.emergencyWithdraw();
    }

    function test_exactInputAndOutputBothDirectionsRemainUsable() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        router.swap(key, true, -int256(1 ether), TickMath.getSqrtPriceAtTick(-500));
        router.swap(key, false, -int256(1 ether), TickMath.getSqrtPriceAtTick(500));
        router.swap(key, true, int256(1 ether), TickMath.getSqrtPriceAtTick(-500));
        router.swap(key, false, int256(1 ether), TickMath.getSqrtPriceAtTick(500));
        assertEq(hook.nextSample(), 4);
        assertTrue(router.hookDeltasWereZero());
    }

    function test_emergencyRedeemsClaimsAndNeedsNoManagerForWithdrawal() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.warp(hook.lastRebalance() + 30 minutes);
        _moveTo(-300);
        assertGt(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        vm.prank(owner);
        hook.activateEmergencyMode();
        assertGt(address(hook).balance, 0);
        // Emergency shares remain redeemable even if the manager is subsequently unavailable.
        vm.etch(address(manager), hex"60006000fd");
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        hook.emergencyWithdraw();
        assertGt(alice.balance, beforeBalance);
        assertEq(hook.balanceOf(alice), 0);
    }

    function test_reentrantEmergencyReceiverCannotRedeemTwice() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        ReenterReceiver receiver = new ReenterReceiver(hook);
        vm.prank(alice);
        hook.transfer(address(receiver), shares);
        vm.prank(owner);
        hook.activateEmergencyMode();
        receiver.exit();
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(receiver.refusal(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hook.balanceOf(address(receiver)), 0);
        assertLe(address(receiver).balance, 10 ether);
    }

    function test_rejectingEthRecipientRollsBackAndCanChooseAnotherReceiver() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        RejectEth receiver = new RejectEth();
        vm.prank(alice);
        hook.transfer(address(receiver), shares);
        vm.prank(owner);
        hook.activateEmergencyMode();
        vm.expectRevert();
        receiver.exit(hook, address(receiver));
        assertEq(hook.balanceOf(address(receiver)), shares);
        uint256 beforeBalance = bob.balance;
        receiver.exit(hook, bob);
        assertEq(hook.balanceOf(address(receiver)), 0);
        assertGt(bob.balance, beforeBalance);
    }
}
