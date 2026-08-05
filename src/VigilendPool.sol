// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVigilendPool} from "./interfaces/IVigilendPool.sol";
import {IVigilendOracle} from "./interfaces/IVigilendOracle.sol";
import {InterestRateModel} from "./interfaces/InterestRateModel.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";

/// @title VigilendPool
/// @notice Core implementation of Vigilend lending pool with deposit, withdraw, borrow, repay & interest accrual
contract VigilendPool is IVigilendPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AssetConfig {
        bool isSupported;
        uint16 ltv; // e.g., 7500 = 75%
        uint16 liquidationThreshold; // e.g., 8000 = 80%
        uint16 liquidationBonus; // e.g., 500 = 5% bonus
        uint8 decimals;
    }

    struct AccountValuation {
        uint256 totalCollateralUSD;
        uint256 totalDebtUSD;
        uint256 weightedLtvSum;
        uint256 weightedThresholdSum;
    }

    IVigilendOracle public immutable oracle;
    InterestRateModel public interestRateModel;

    mapping(address => AssetConfig) public assetConfigs;
    address[] public supportedAssets;

    mapping(address => mapping(address => uint256)) public userCollateralShares;
    mapping(address => uint256) public totalCollateralShares;
    mapping(address => uint256) public totalCollateralAmount;

    // --- Debt & Interest Tracking State Variables ---
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

        if (!assetConfigs[asset].isSupported) {
            supportedAssets.push(asset);
        }

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

        uint256 totalCash = IERC20(asset).balanceOf(address(this));
        uint256 totalDebt = (totalDebtShares[asset] * borrowIndex[asset]) / 1e18;

        if (totalDebt == 0) return;

        uint256 borrowRate = interestRateModel.calculateBorrowRate(totalCash, totalDebt);
        // Linear interest factor: (borrowRate * timeDelta) / 365 days
        uint256 interestFactor = (borrowRate * timeDelta) / 365 days;
        uint256 newBorrowIndex = (borrowIndex[asset] * (1e18 + interestFactor)) / 1e18;

        borrowIndex[asset] = newBorrowIndex;
    }

    /// @inheritdoc IVigilendPool
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override nonReentrant returns (uint256 shares) {
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
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override nonReentrant returns (uint256 sharesBurned) {
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

        // Check health factor post withdrawal to prevent withdrawing collateral while borrowing
        (,,,,, uint256 healthFactor) = getUserAccountData(msg.sender);
        if (healthFactor < 1e18) revert HealthFactorTooLow();

        IERC20(asset).safeTransfer(to, amount);

        emit Withdraw(asset, msg.sender, to, amount, sharesBurned);
    }

    /// @inheritdoc IVigilendPool
    function borrow(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (!assetConfigs[asset].isSupported) revert AssetNotSupported();
        if (onBehalfOf == address(0)) revert ZeroAddress();

        accrueInterest(asset);

        require(IERC20(asset).balanceOf(address(this)) >= amount, "INSUFFICIENT_POOL_LIQUIDITY");

        uint256 newShares = (amount * 1e18) / borrowIndex[asset];
        if (newShares == 0) revert InvalidAmount();

        userDebtShares[asset][onBehalfOf] += newShares;
        totalDebtShares[asset] += newShares;

        // Check LTV borrow limit and health factor post borrow
        (uint256 totalCollateralUSD, uint256 totalDebtUSD,, , uint256 ltv, uint256 healthFactor) = getUserAccountData(onBehalfOf);
        uint256 maxBorrowUSD = (totalCollateralUSD * ltv) / 10000;
        if (totalDebtUSD > maxBorrowUSD || healthFactor < 1e18) revert InsufficientCollateral();

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, onBehalfOf, amount);
    }

    /// @inheritdoc IVigilendPool
    function repay(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override nonReentrant returns (uint256 repaidAmount) {
        if (amount == 0) revert InvalidAmount();
        if (!assetConfigs[asset].isSupported) revert AssetNotSupported();
        if (onBehalfOf == address(0)) revert ZeroAddress();

        accrueInterest(asset);

        uint256 userDebtAmount = (userDebtShares[asset][onBehalfOf] * borrowIndex[asset]) / 1e18;
        require(userDebtAmount > 0, "NO_DEBT");

        repaidAmount = amount > userDebtAmount ? userDebtAmount : amount;

        // Conservative calculation: round up debt shares to burn
        uint256 sharesToBurn = (repaidAmount * 1e18 + borrowIndex[asset] - 1) / borrowIndex[asset];
        if (sharesToBurn > userDebtShares[asset][onBehalfOf]) {
            sharesToBurn = userDebtShares[asset][onBehalfOf];
        }

        userDebtShares[asset][onBehalfOf] -= sharesToBurn;
        totalDebtShares[asset] -= sharesToBurn;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repaidAmount);

        emit Repay(asset, msg.sender, onBehalfOf, repaidAmount);
    }

    /// @inheritdoc IVigilendPool
    function liquidate(
        address collateralAsset,
        address debtAsset,
        address borrower,
        uint256 debtToCover
    ) external override returns (uint256 liquidatedCollateral) {
        if (debtToCover == 0) revert InvalidAmount();
        if (!assetConfigs[collateralAsset].isSupported || !assetConfigs[debtAsset].isSupported) {
            revert AssetNotSupported();
        }
        if (borrower == address(0)) revert ZeroAddress();

        accrueInterest(collateralAsset);
        accrueInterest(debtAsset);

        // Verify borrower is actually undercollateralized (Health Factor < 1.0)
        (,,,,, uint256 healthFactor) = getUserAccountData(borrower);
        if (healthFactor >= 1e18) revert HealthFactorOk();

        uint256 userDebtAmount = (userDebtShares[debtAsset][borrower] * borrowIndex[debtAsset]) / 1e18;
        require(userDebtAmount > 0, "NO_DEBT");

        // Close factor: Liquidate max 50% of borrower debt per tx, unless debt is very small
        uint256 maxDebtToCover = userDebtAmount / 2;
        uint256 actualDebtToCover = debtToCover > maxDebtToCover ? maxDebtToCover : debtToCover;
        if (actualDebtToCover == 0) actualDebtToCover = userDebtAmount;

        // Calculate USD value of debt covered
        (uint256 debtPrice, uint8 debtPriceDecimals) = oracle.getPrice(debtAsset);
        require(oracle.isFresh(debtAsset), "STALE_PRICE");
        uint256 debtScale = (10 ** assetConfigs[debtAsset].decimals) * (10 ** debtPriceDecimals);
        uint256 debtCoveredUSD = (actualDebtToCover * debtPrice * 1e18) / debtScale;

        // Calculate collateral value with liquidation bonus
        uint256 collateralValueWithBonusUSD = (debtCoveredUSD * (10000 + assetConfigs[collateralAsset].liquidationBonus)) / 10000;

        (uint256 collateralPrice, uint8 collateralPriceDecimals) = oracle.getPrice(collateralAsset);
        require(oracle.isFresh(collateralAsset), "STALE_PRICE");
        uint256 collateralScale = (10 ** assetConfigs[collateralAsset].decimals) * (10 ** collateralPriceDecimals);
        liquidatedCollateral = (collateralValueWithBonusUSD * collateralScale) / (collateralPrice * 1e18);

        // Cap seized collateral to borrower's actual collateral
        uint256 userCollateralAmount = (userCollateralShares[collateralAsset][borrower] * totalCollateralAmount[collateralAsset]) / totalCollateralShares[collateralAsset];
        if (liquidatedCollateral > userCollateralAmount) {
            liquidatedCollateral = userCollateralAmount;
        }

        // Execute debt shares reduction
        uint256 debtSharesToBurn = (actualDebtToCover * 1e18 + borrowIndex[debtAsset] - 1) / borrowIndex[debtAsset];
        if (debtSharesToBurn > userDebtShares[debtAsset][borrower]) {
            debtSharesToBurn = userDebtShares[debtAsset][borrower];
        }
        userDebtShares[debtAsset][borrower] -= debtSharesToBurn;
        totalDebtShares[debtAsset] -= debtSharesToBurn;

        // Execute collateral shares transfer to liquidator (msg.sender)
        uint256 collateralSharesToSeize = (liquidatedCollateral * totalCollateralShares[collateralAsset]) / totalCollateralAmount[collateralAsset];
        if (collateralSharesToSeize > userCollateralShares[collateralAsset][borrower]) {
            collateralSharesToSeize = userCollateralShares[collateralAsset][borrower];
        }
        userCollateralShares[collateralAsset][borrower] -= collateralSharesToSeize;
        userCollateralShares[collateralAsset][msg.sender] += collateralSharesToSeize;

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualDebtToCover);

        emit Liquidate(collateralAsset, debtAsset, borrower, msg.sender, actualDebtToCover, liquidatedCollateral);
    }

    /// @inheritdoc IVigilendPool
    function flashLoan(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params
    ) external override nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (!assetConfigs[asset].isSupported) revert AssetNotSupported();
        if (receiverAddress == address(0)) revert ZeroAddress();

        uint256 availableLiquidity = IERC20(asset).balanceOf(address(this));
        require(availableLiquidity >= amount, "INSUFFICIENT_POOL_LIQUIDITY");

        uint256 premium = (amount * 9) / 10000; // 0.09% fee

        IERC20(asset).safeTransfer(receiverAddress, amount);

        require(
            IFlashLoanReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params),
            "FLASHLOAN_EXECUTION_FAILED"
        );

        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + premium);

        emit FlashLoan(receiverAddress, msg.sender, asset, amount, premium);
    }

    /// @inheritdoc IVigilendPool
    function getUserAccountData(address user)
        public
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
        AccountValuation memory valuation;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            AssetConfig memory config = assetConfigs[asset];
            if (!config.isSupported) continue;

            (uint256 price, uint8 priceDecimals) = oracle.getPrice(asset);
            require(oracle.isFresh(asset), "STALE_PRICE");

            uint256 priceScale = (10 ** config.decimals) * (10 ** priceDecimals);

            // Collateral USD calculation
            uint256 uShares = userCollateralShares[asset][user];
            if (uShares > 0 && totalCollateralShares[asset] > 0) {
                uint256 cAmount = (uShares * totalCollateralAmount[asset]) / totalCollateralShares[asset];
                uint256 cUSD = (cAmount * price * 1e18) / priceScale;

                valuation.totalCollateralUSD += cUSD;
                valuation.weightedLtvSum += cUSD * config.ltv;
                valuation.weightedThresholdSum += cUSD * config.liquidationThreshold;
            }

            // Debt USD calculation
            uint256 dShares = userDebtShares[asset][user];
            if (dShares > 0) {
                uint256 dAmount = (dShares * borrowIndex[asset]) / 1e18;
                uint256 dUSD = (dAmount * price * 1e18) / priceScale;

                valuation.totalDebtUSD += dUSD;
            }
        }

        totalCollateralUSD = valuation.totalCollateralUSD;
        totalDebtUSD = valuation.totalDebtUSD;

        if (totalCollateralUSD > 0) {
            ltv = valuation.weightedLtvSum / totalCollateralUSD;
            currentLiquidationThreshold = valuation.weightedThresholdSum / totalCollateralUSD;

            uint256 maxBorrowUSD = (totalCollateralUSD * ltv) / 10000;
            if (maxBorrowUSD > totalDebtUSD) {
                availableBorrowsUSD = maxBorrowUSD - totalDebtUSD;
            }
        }

        if (totalDebtUSD == 0) {
            healthFactor = type(uint256).max;
        } else {
            healthFactor = (totalCollateralUSD * currentLiquidationThreshold * 1e18) / (10000 * totalDebtUSD);
        }
    }
}
