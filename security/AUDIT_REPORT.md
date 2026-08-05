# Vigilend Protocol — Security Audit & Code Review Report

**Date:** 2026-08-05  
**Target Contracts:** [`VigilendPool.sol`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol), [`FlashLiquidationReceiver.sol`](file:///home/zeth/Desktop/vigilend/src/FlashLiquidationReceiver.sol), [`InterestRateModel.sol`](file:///home/zeth/Desktop/vigilend/src/interfaces/InterestRateModel.sol)  
**Status:** Audit Complete

---

## Executive Summary

A comprehensive line-by-line security review was performed on the core Solidity smart contracts of the Vigilend protocol. The audit evaluated precision handling, rounding directions, access controls, reentrancy resilience, oracle integrations, and liquidation mechanics.

| Severity | Count | Resolved |
|---|---|---|
| **High** | 1 | 1 |
| **Medium** | 2 | 1 |
| **Low** | 2 | 0 |
| **Informational** | 2 | 0 |

---

## Detailed Audit Findings

### [H-01] Debt Share Rounding Down On `borrow()` Allows Debt Under-counting

- **Severity:** High
- **Category:** Accounting & Precision Loss
- **Affected File:** [`VigilendPool.sol:L204`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol#L204)
- **Description:**
  In `VigilendPool.borrow()`, the newly minted debt shares for a borrower are calculated as:
  ```solidity
  uint256 newShares = (amount * 1e18) / borrowIndex[asset];
  ```
  Integer division in Solidity rounds down. When a user borrows `amount` tokens, rounding down the debt shares means the protocol records fewer debt shares than required to represent the full borrowed amount. When the user later repays or debt is computed (`userDebtShares * borrowIndex / 1e18`), the resulting debt amount is less than the actual cash transferred out of the pool. Over time and across repeated borrows, borrowers can drain small amounts of protocol liquidity without corresponding debt obligations.
- **Recommendation:**
  Round up the minted debt shares on `borrow()` to favor protocol solvency:
  ```solidity
  uint256 newShares = (amount * 1e18 + borrowIndex[asset] - 1) / borrowIndex[asset];
  ```

---

### [M-01] Unrelated Stale Oracle Price Blocks Protocol-Wide Operations

- **Severity:** Medium
- **Category:** Availability & Oracle Dependency
- **Affected File:** [`VigilendPool.sol:L364-L370`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol#L364-L370)
- **Description:**
  In `getUserAccountData()`, the function iterates over **all** `supportedAssets`:
  ```solidity
  for (uint256 i = 0; i < supportedAssets.length; i++) {
      address asset = supportedAssets[i];
      ...
      (uint256 price, uint8 priceDecimals) = oracle.getPrice(asset);
      require(oracle.isFresh(asset), "STALE_PRICE");
      ...
  }
  ```
  Because `withdraw()`, `borrow()`, and `liquidate()` call `getUserAccountData()`, if **any single** supported asset's oracle feed becomes stale or paused, `getUserAccountData()` will revert. This locks all user funds, withdrawals, and liquidations across the entire protocol, even for users who do not hold or borrow the affected asset.
- **Recommendation:**
  Only query and validate oracle freshness for assets in which the user currently has non-zero collateral shares or debt shares (or the asset being borrowed/withdrawn).

---

### [M-02] Absence of Bad Debt Socialization Creates Permanent Insolvency Traps

- **Severity:** Medium
- **Category:** Protocol Risk & Liquidation Mechanics
- **Affected File:** [`VigilendPool.sol:L252-L318`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol#L252-L318)
- **Description:**
  When a borrower's collateral value drops below their total debt value (e.g. during extreme market volatility), liquidating the position seizes 100% of the collateral but leaves remaining debt shares in `userDebtShares` and `totalDebtShares`. Because there is no remaining collateral to seize, liquidators have no economic incentive to clear the remaining debt ("bad debt"). The unbacked debt remains in `totalDebtShares`, distorting pool accounting and interest rate calculations indefinitely.
- **Recommendation:**
  Introduce a bad debt recognition and socialization mechanism (e.g., protocol reserve absorption or bad debt write-off function triggered when collateral reaches 0).

---

### [L-01] Linear Interest Rate Model Ignores Compounding Over Inactive Periods

- **Severity:** Low
- **Category:** Mathematical Modeling
- **Affected File:** [`VigilendPool.sol:L114-L117`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol#L114-L117)
- **Description:**
  Interest is accrued linearly via:
  $$\text{interestFactor} = \frac{\text{borrowRate} \times \Delta t}{365 \text{ days}}$$
  If a pool remains inactive for long periods (e.g., months without state transitions), linear interest calculation undercharges borrowers compared to continuous or compound interest ($e^{r t} - 1$ or EIP-4626 compound accrual).
- **Recommendation:**
  For high-yield or long-duration markets, consider binomial approximation or compound interest models used by Aave/Compound ($1 + r/n)^n$.

---

### [L-02] Potential Gas Exhaustion in `getUserAccountData()` with Large Asset List

- **Severity:** Low
- **Category:** Denial of Service (Gas Limit)
- **Affected File:** [`VigilendPool.sol:L364`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol#L364)
- **Description:**
  As the number of `supportedAssets` grows, iterating through all assets in `getUserAccountData()` consumes increasing amounts of gas. If `supportedAssets.length` becomes large, calls to `withdraw()`, `borrow()`, and `liquidate()` may exceed block gas limits.
- **Recommendation:**
  Maintain per-user active asset lists (bitmaps or arrays of active user assets) so valuation loops only iterate over assets relevant to the specific account.

---

### [I-01] OpenZeppelin SafeERC20 `forceApprove` Usage in `FlashLiquidationReceiver`

- **Severity:** Informational
- **Category:** Best Practices
- **Affected File:** [`FlashLiquidationReceiver.sol:L36`](file:///home/zeth/Desktop/vigilend/src/FlashLiquidationReceiver.sol#L36)
- **Description:**
  `FlashLiquidationReceiver` uses `forceApprove(pool, amount)` which sets allowance to 0 before setting the target amount. While secure, using exact allowances or resetting to 0 post-liquidation improves code clarity.
- **Recommendation:**
  Explicitly reset allowance to 0 at the end of `executeOperation()`.

---

### [I-02] Unchecked Return Value on Non-Standard ERC-20 Tokens

- **Severity:** Informational
- **Category:** Token Compatibility
- **Affected File:** [`VigilendPool.sol`](file:///home/zeth/Desktop/vigilend/src/VigilendPool.sol)
- **Description:**
  The pool correctly uses OpenZeppelin `SafeERC20` for all transfers, mitigating non-standard ERC-20 return values (e.g. USDT missing boolean return). Fee-on-transfer tokens are not supported by design and should be documented in market configuration guidelines.
- **Recommendation:**
  Explicitly document token requirements (no fee-on-transfer, 18 or 6 standard decimals) in `AGENTS.md` and user documentation.

---

## Conclusion & Verification Checklist

- [x] Line-by-line review of `VigilendPool.sol`
- [x] Precision and rounding direction verification
- [x] Oracle interaction and freshness check evaluation
- [x] Non-reentrancy and access control verification
- [x] Invariant and unit tests confirmed passing (`forge test`)
