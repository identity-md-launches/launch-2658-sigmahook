// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ISigmaBasket is IERC20 {
    function totalAssets() external view returns (uint256 amount0, uint256 amount1);
}

/// @notice ERC-4626 vToken over SigmaHook's two-currency basket receipts.
/// @dev The ERC-4626 asset is the receipt, not a spot-price valuation in either pool currency.
/// Every receipt owns LP principal, net accrued fees and idle inventory. No admin or asset sweep.
contract SigmaVault is ERC4626 {
    using SafeERC20 for IERC20;

    error InvalidAsset();
    error ZeroShares();

    constructor(IERC20 basket_) ERC20("SigmaHook Vault Share", "svSHK") ERC4626(basket_) {
        if (address(basket_) == address(0)) revert InvalidAsset();
    }

    /// @notice Look through a vToken balance to its pro-rata pool currencies, rounded down.
    function underlyingAssets(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        ISigmaBasket basket = ISigmaBasket(asset());
        uint256 supply = basket.totalSupply();
        if (supply == 0) return (0, 0);
        uint256 receipts = convertToAssets(shares);
        (amount0, amount1) = basket.totalAssets();
        amount0 = Math.mulDiv(amount0, receipts, supply);
        amount1 = Math.mulDiv(amount1, receipts, supply);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets != 0 && shares == 0) revert ZeroShares();
        // All public ERC-4626 entrypoints source assets exclusively from their caller.
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }
}
