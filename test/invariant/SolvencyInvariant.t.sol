// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VigilendPool} from "../../src/VigilendPool.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {InterestRateModel} from "../../src/interfaces/InterestRateModel.sol";
import {Handler} from "./Handler.sol";

contract SolvencyInvariantTest is Test {
    VigilendPool public pool;
    MockOracle public oracle;
    MockERC20 public weth;
    MockERC20 public usdc;
    Handler public handler;

    function setUp() public {
        oracle = new MockOracle();
        pool = new VigilendPool(address(oracle));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        pool.setAssetConfig(address(weth), 7500, 8000, 500, 18);
        pool.setAssetConfig(address(usdc), 8500, 9000, 500, 6);

        InterestRateModel rateModel = new InterestRateModel();
        pool.setInterestRateModel(address(rateModel));

        oracle.setPrice(address(weth), 3000 * 1e8);
        oracle.setPrice(address(usdc), 1 * 1e8);

        handler = new Handler(pool, oracle, weth, usdc);
        targetContract(address(handler));
    }

    /// @notice Invariant: Total collateral shares in pool must strictly equal the sum of all individual user collateral shares
    function invariant_SolvencySumShares() public view {
        assertEq(pool.totalCollateralShares(address(weth)), handler.ghost_sumWethShares());
        assertEq(pool.totalCollateralShares(address(usdc)), handler.ghost_sumUsdcShares());
    }

    /// @notice Invariant: Total debt shares in pool must strictly equal the sum of all individual user debt shares
    function invariant_DebtSumShares() public view {
        assertEq(pool.totalDebtShares(address(usdc)), handler.ghost_sumUsdcDebtShares());
    }
}
