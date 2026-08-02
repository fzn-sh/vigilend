// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IVigilendOracle
/// @notice Interface for retrieving validated asset prices and freshness for Vigilend protocol
interface IVigilendOracle {
    /// @notice Returns the price of an asset in USD (standardized decimals, e.g., 8 decimals)
    /// @param asset The address of the underlying ERC-20 token
    /// @return price Price of the asset in USD with specified decimals
    /// @return decimals The decimal precision of the returned price
    function getPrice(address asset) external view returns (uint256 price, uint8 decimals);

    /// @notice Checks if the oracle data for an asset is valid and fresh
    /// @param asset The address of the underlying ERC-20 token
    /// @return fresh True if price is up to date and valid, false otherwise
    function isFresh(address asset) external view returns (bool fresh);
}
