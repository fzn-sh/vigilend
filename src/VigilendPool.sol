// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVigilendPool} from "./interfaces/IVigilendPool.sol";
import {IVigilendOracle} from "./interfaces/IVigilendOracle.sol";
import {InterestRateModel} from "./interfaces/InterestRateModel.sol";

/// @title VigilendPool
/// @notice Core implementation of Vigilend lending pool with interest accrual
contract VigilendPool is IVigilendPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AssetConfig {
        bool isSupported;
        uint16 ltv; // e.g., 7500 = 75%
        uint16 liquidationThreshold; // e.g., 8000 = 80%
        uint16 liquidationBonus; // e.g., 500 = 5% bonus
        uint8 decimals;
    }

    IVigilendOracle public immutable oracle;
    InterestRateModel public interestRateModel;

    mapping(address => AssetConfig) public assetConfigs;
    mapping(address => mapping(address => uint256)) public userCollateralShares;
    mapping(address => uint256) public totalCollateralShares;
    mapping(address => uint256) public totalCollateralAmount;

    // Debt & Interest Tracking State Variables
    mapping(address => uint256) public borrowIndex; // Scaled by 1e18
    mapping(address => uint256) public lastUpdateTimestamp;
    mapping(address => uint256) public totalDebtShares;
    mapping(address => mapping(address => uint256)) public userDebtShares;

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED");
        _;
    }

    constructor(address oracle_) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IVigilendOracle(oracle_);
        owner = msg.sender;
    }

    /// @notice Configure market parameters for a supported asset
    function setAssetConfig(
        address asset,
        uint16 ltv,
        uint16 liquidationThreshold,
        uint16 liquidationBonus,
        uint8 decimals
    ) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        require(ltv <= liquidationThreshold, "INVALID_LTV");
        require(liquidationThreshold <= 10000, "INVALID_THRESHOLD");

        assetConfigs[asset] = AssetConfig({
            isSupported: true,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            decimals: decimals
        });

        if (borrowIndex[asset] == 0) {
            borrowIndex[asset] = 1e18;
            lastUpdateTimestamp[asset] = block.timestamp;
        }
    }

    /// @notice Set the interest rate strategy contract
    function setInterestRateModel(address interestRateModel_) external onlyOwner {
        if (interestRateModel_ == address(0)) revert ZeroAddress();
        interestRateModel = InterestRateModel(interestRateModel_);
    }

    /// @notice Accrue interest for a specific asset based on elapsed time and utilization rate
    function accrueInterest(address asset) public {
        uint256 lastTimestamp = lastUpdateTimestamp[asset];
        if (lastTimestamp == 0 || block.timestamp == lastTimestamp) {
            return;
        }

        uint256 timeDelta = block.timestamp - lastTimestamp;
        lastUpdateTimestamp[asset] = block.timestamp;

        if (address(interestRateModel) == address(0)) return;

        uint256 totalCash = totalCollateralAmount[asset];
        uint256 totalDebt = (totalDebtShares[asset] * borrowIndex[asset]) / 1e18;

        if (totalDebt == 0) return;

        uint256 borrowRate = interestRateModel.calculateBorrowRate(totalCash, totalDebt);
        // Linear interest factor: (borrowRate * timeDelta) / 365 days
        uint256 interestFactor = (borrowRate * timeDelta) / 365 days;
        uint256 newBorrowIndex = (borrowIndex[asset] * (1e18 + interestFactor)) / 1e18;

        borrowIndex[asset] = newBorrowIndex;
    }

    /// @inheritdoc IVigilendPool
    function deposit(address asset, uint256 amount, address onBehalfOf)
        external
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert InvalidAmount();
        if (!assetConfigs[asset].isSupported) revert AssetNotSupported();
        if (onBehalfOf == address(0)) revert ZeroAddress();

        accrueInterest(asset);

        uint256 totalShares = totalCollateralShares[asset];
        uint256 totalAmount = totalCollateralAmount[asset];

        // Conservative share calculation: 1:1 if initial deposit, rounding down for subsequent
        if (totalShares == 0 || totalAmount == 0) {
            shares = amount;
        } else {
            shares = (amount * totalShares) / totalAmount;
        }

        if (shares == 0) revert InvalidAmount();

        userCollateralShares[asset][onBehalfOf] += shares;
        totalCollateralShares[asset] += shares;
        totalCollateralAmount[asset] += amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(asset, msg.sender, onBehalfOf, amount, shares);
    }

    /// @inheritdoc IVigilendPool
    function withdraw(address asset, uint256 amount, address to)
        external
        override
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (amount == 0) revert InvalidAmount();
        if (!assetConfigs[asset].isSupported) revert AssetNotSupported();
        if (to == address(0)) revert ZeroAddress();

        accrueInterest(asset);

        uint256 totalShares = totalCollateralShares[asset];
        uint256 totalAmount = totalCollateralAmount[asset];

        require(totalAmount > 0 && totalShares > 0, "INSUFFICIENT_LIQUIDITY");

        // Conservative calculation: round up shares burned to prevent protocol loss
        sharesBurned = (amount * totalShares + totalAmount - 1) / totalAmount;

        require(userCollateralShares[asset][msg.sender] >= sharesBurned, "INSUFFICIENT_BALANCE");

        userCollateralShares[asset][msg.sender] -= sharesBurned;
        totalCollateralShares[asset] -= sharesBurned;
        totalCollateralAmount[asset] -= amount;

        IERC20(asset).safeTransfer(to, amount);

        emit Withdraw(asset, msg.sender, to, amount, sharesBurned);
    }

    /// @inheritdoc IVigilendPool
    function borrow(address, uint256, address) external pure override {
        revert("NOT_IMPLEMENTED_YET");
    }

    /// @inheritdoc IVigilendPool
    function repay(address, uint256, address) external pure override returns (uint256) {
        revert("NOT_IMPLEMENTED_YET");
    }

    /// @inheritdoc IVigilendPool
    function liquidate(address, address, address, uint256) external pure override returns (uint256) {
        revert("NOT_IMPLEMENTED_YET");
    }

    /// @inheritdoc IVigilendPool
    function getUserAccountData(address user)
        external
        view
        override
        returns (
            uint256 totalCollateralUSD,
            uint256 totalDebtUSD,
            uint256 availableBorrowsUSD,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        // Initial stub for deposit-only phase
        totalDebtUSD = 0;
        availableBorrowsUSD = 0;
        healthFactor = type(uint256).max;
        currentLiquidationThreshold = 0;
        ltv = 0;
        totalCollateralUSD = 0;
    }
}
