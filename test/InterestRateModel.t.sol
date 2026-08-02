// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../src/interfaces/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel public rateModel;

    function setUp() public {
        rateModel = new InterestRateModel();
    }

    function test_ZeroUtilization() public view {
        uint256 util = rateModel.calculateUtilization(100 ether, 0);
        uint256 borrowRate = rateModel.calculateBorrowRate(100 ether, 0);

        assertEq(util, 0);
        assertEq(borrowRate, 0.02e18); // Base Rate 2%
    }

    function test_HalfUtilization() public view {
        // 50 Cash, 50 Borrows -> 50% Utilization
        uint256 util = rateModel.calculateUtilization(50 ether, 50 ether);
        uint256 borrowRate = rateModel.calculateBorrowRate(50 ether, 50 ether);

        assertEq(util, 0.5e18); // 50%
        // BaseRate (2%) + 50%/80% * 4% = 2% + 2.5% = 4.5% (0.045e18)
        assertEq(borrowRate, 0.045e18);
    }

    function test_OptimalUtilization() public view {
        // 20 Cash, 80 Borrows -> 80% Utilization
        uint256 util = rateModel.calculateUtilization(20 ether, 80 ether);
        uint256 borrowRate = rateModel.calculateBorrowRate(20 ether, 80 ether);

        assertEq(util, 0.8e18); // 80%
        // BaseRate (2%) + Slope1 (4%) = 6% (0.06e18)
        assertEq(borrowRate, 0.06e18);
    }

    function test_HighUtilization() public view {
        // 10 Cash, 90 Borrows -> 90% Utilization
        uint256 util = rateModel.calculateUtilization(10 ether, 90 ether);
        uint256 borrowRate = rateModel.calculateBorrowRate(10 ether, 90 ether);

        assertEq(util, 0.9e18); // 90%
        // BaseRate (2%) + Slope1 (4%) + (10%/20% * 60%) = 6% + 30% = 36% (0.36e18)
        assertEq(borrowRate, 0.36e18);
    }

    function test_FullUtilization() public view {
        // 0 Cash, 100 Borrows -> 100% Utilization
        uint256 util = rateModel.calculateUtilization(0, 100 ether);
        uint256 borrowRate = rateModel.calculateBorrowRate(0, 100 ether);

        assertEq(util, 1e18); // 100%
        // BaseRate (2%) + Slope1 (4%) + Slope2 (60%) = 66% (0.66e18)
        assertEq(borrowRate, 0.66e18);
    }
}
