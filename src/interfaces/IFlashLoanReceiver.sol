// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFlashLoanReceiver
/// @notice Interface for contracts executing Flash Loans from VigilendPool
interface IFlashLoanReceiver {
    /// @notice Executed by VigilendPool after transferring flash-loaned funds
    /// @param asset Address of the flash-loaned ERC-20 token
    /// @param amount Amount of tokens flash-loaned
    /// @param premium Fee charged for the flash loan
    /// @param initiator Address that initiated the flash loan
    /// @param params Arbitrary call data passed from flashLoan call
    /// @return success True if the operation succeeded and funds can be pulled back
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool success);
}
