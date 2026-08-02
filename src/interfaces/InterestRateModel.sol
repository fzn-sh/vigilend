// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract InterestRateModel {
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18; // 80%
    uint256 public constant BASE_RATE = 0.02e18; // 2%
    uint256 public constant SLOPE1 = 0.04e18; // 4%
    uint256 public constant SLOPE2 = 0.6e18; // 60%

    function calculateUtilization(uint256 totalCash, uint256 totalBorrows) public pure returns (uint256 utilization) {
        uint256 totalPool = totalCash + totalBorrows;

        if (totalPool == 0) {
            return 0;
        }

        return (totalBorrows * 1e18) / totalPool;
    }

    function calculateBorrowRate(uint256 totalCash, uint256 totalBorrows) public pure returns (uint256 borrowRate) {
        uint256 util = calculateUtilization(totalCash, totalBorrows);

        if (util <= OPTIMAL_UTILIZATION) {
            borrowRate = BASE_RATE + (util * SLOPE1) / OPTIMAL_UTILIZATION;
        } else {
            borrowRate = BASE_RATE + SLOPE1 + ((util - OPTIMAL_UTILIZATION) * SLOPE2) / (1e18 - OPTIMAL_UTILIZATION);
        }
    }
}
