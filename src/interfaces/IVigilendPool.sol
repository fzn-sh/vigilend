// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IVigilendPool
/// @notice Core interface for Vigilend lending and borrowing pool
interface IVigilendPool {
    event Deposit(
        address indexed asset, address indexed user, address indexed onBehalfOf, uint256 amount, uint256 shares
    );
    event Withdraw(
        address indexed asset, address indexed user, address indexed to, uint256 amount, uint256 sharesBurned
    );
    event Borrow(address indexed asset, address indexed user, address indexed onBehalfOf, uint256 amount);
    event Repay(address indexed asset, address indexed user, address indexed onBehalfOf, uint256 amount);
    event Liquidate(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed borrower,
        address liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event FlashLoan(
        address indexed target, address indexed initiator, address indexed asset, uint256 amount, uint256 premium
    );

    error InvalidAmount();
    error AssetNotSupported();
    error InsufficientCollateral();
    error HealthFactorOk();
    error HealthFactorTooLow();
    error StalePrice();
    error ZeroAddress();
    error FlashLoanFailed();

    /// @notice Supply assets into the protocol to earn interest or use as collateral
    /// @param asset Address of the ERC-20 token to deposit
    /// @param amount Amount of tokens to deposit
    /// @param onBehalfOf Beneficiary address receiving the deposit credit
    /// @return shares Amount of pool shares minted
    function deposit(address asset, uint256 amount, address onBehalfOf) external returns (uint256 shares);

    /// @notice Withdraw supplied assets from the protocol
    /// @param asset Address of the ERC-20 token to withdraw
    /// @param amount Amount of tokens to withdraw
    /// @param to Destination address receiving the withdrawn tokens
    /// @return sharesBurned Amount of pool shares burned
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 sharesBurned);

    /// @notice Borrow assets against deposited collateral
    /// @param asset Address of the ERC-20 token to borrow
    /// @param amount Amount of tokens to borrow
    /// @param onBehalfOf Address incurring the debt
    function borrow(address asset, uint256 amount, address onBehalfOf) external;

    /// @notice Repay borrowed debt
    /// @param asset Address of the ERC-20 token to repay
    /// @param amount Amount of debt to repay
    /// @param onBehalfOf Address whose debt is being repaid
    /// @return repaidAmount Actual amount repaid
    function repay(address asset, uint256 amount, address onBehalfOf) external returns (uint256 repaidAmount);

    /// @notice Liquidate an undercollateralized borrow position (Health Factor < 1.0)
    /// @param collateralAsset Collateral asset to seize
    /// @param debtAsset Borrowed debt asset to liquidate
    /// @param borrower Address of the borrower being liquidated
    /// @param debtToCover Amount of debt to repay
    /// @return liquidatedCollateral Amount of collateral token seized by liquidator
    function liquidate(address collateralAsset, address debtAsset, address borrower, uint256 debtToCover)
        external
        returns (uint256 liquidatedCollateral);

    /// @notice Execute an uncollateralized Flash Loan
    /// @param receiverAddress Contract executing IFlashLoanReceiver interface
    /// @param asset Token to flash-loan
    /// @param amount Amount of tokens to flash-loan
    /// @param params Custom calldata forwarded to executeOperation
    function flashLoan(address receiverAddress, address asset, uint256 amount, bytes calldata params) external;

    /// @notice Get account health status and collateral/debt values in USD
    /// @param user Address of the user
    /// @return totalCollateralUSD Total value of user's collateral in USD (18 decimals)
    /// @return totalDebtUSD Total value of user's debt in USD (18 decimals)
    /// @return availableBorrowsUSD Max additional USD user can borrow
    /// @return currentLiquidationThreshold Weighted average liquidation threshold (basis points, 10000 = 100%)
    /// @return ltv Weighted average Loan-to-Value (basis points, 10000 = 100%)
    /// @return healthFactor Health factor (18 decimals, < 1e18 means liquidatable)
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralUSD,
            uint256 totalDebtUSD,
            uint256 availableBorrowsUSD,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
