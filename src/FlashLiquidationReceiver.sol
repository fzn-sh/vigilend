// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";
import {IVigilendPool} from "./interfaces/IVigilendPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FlashLiquidationReceiver
/// @notice Custom Flash Loan Receiver contract executing capital-free liquidations
contract FlashLiquidationReceiver is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    address public immutable pool;
    address public immutable owner;

    constructor(address pool_) {
        pool = pool_;
        owner = msg.sender;
    }

    /// @inheritdoc IFlashLoanReceiver
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        override
        returns (bool success)
    {
        require(msg.sender == pool, "ONLY_POOL");
        require(initiator == owner, "UNAUTHORIZED_INITIATOR");

        (address collateralAsset, address borrower) = abi.decode(params, (address, address));

        // 1. Approve pool to pull debt asset for liquidation
        IERC20(asset).forceApprove(pool, amount);

        // 2. Liquidate undercollateralized borrower position
        uint256 collateralSeized = IVigilendPool(pool).liquidate(collateralAsset, asset, borrower, amount);

        // 3. Approve pool to pull back flash loan principal + fee premium
        uint256 amountToRepay = amount + premium;
        IERC20(asset).forceApprove(pool, amountToRepay);

        // 4. Transfer remaining seized collateral WETH to bot owner
        if (collateralSeized > 0) {
            IERC20(collateralAsset).safeTransfer(owner, IERC20(collateralAsset).balanceOf(address(this)));
        }

        // Transfer any leftover debt asset USDC to bot owner
        uint256 leftoverDebtAsset = IERC20(asset).balanceOf(address(this));
        if (leftoverDebtAsset > amountToRepay) {
            IERC20(asset).safeTransfer(owner, leftoverDebtAsset - amountToRepay);
        }

        return true;
    }
}
