# Vigilend Protocol — Threat Model & Security Architecture

**Last Updated:** 2026-08-05  
**Target Scope:** `src/VigilendPool.sol`, `src/FlashLiquidationReceiver.sol`, `src/interfaces/*`  
**Protocol Version:** Milestone 1 (End-to-End Vertical Slice)

---

## 1. System Overview & Trust Boundaries

Vigilend is a modular, overcollateralized lending protocol allowing users to deposit ERC-20 assets as collateral, borrow supported debt assets against their collateral, earn interest, and participate in uncollateralized flash loans or liquidations.

```
                     +-----------------------+
                     |    Admin / Owner      |
                     +-----------+-----------+
                                 | setAssetConfig / setInterestRateModel
                                 v
+--------------+    +-----------------------+    +------------------------+
| Depositor    |--->|     VigilendPool      |<---| Borrower               |
| (Supplier)   |<---|  (Core Accounting)    |--->|                        |
+--------------+    +---+---------------+---+    +------------------------+
                        |               |
                        v               v
             +--------------+       +-------------------+
             | IVigilend    |       | InterestRateModel |
             | Oracle       |       +-------------------+
             +--------------+
                        ^
                        | liquidation / flashLoan
             +----------+------------+
             | Liquidator / Bot      |
             | FlashLiquidationRecv  |
             +-----------------------+
```

### Trust Boundaries & Assumptions

1. **Price Oracle (`IVigilendOracle`):** 
   - **Assumption:** Oracle provides fresh, validated USD prices via `getPrice(asset)` and `isFresh(asset)`.
   - **Trust Boundary:** External dependency. Malicious or stale oracle data breaks borrowing limits and liquidation safety.
2. **ERC-20 Assets:**
   - **Assumption:** Standard ERC-20 tokens without fee-on-transfer, rebasing, or reentrant transfer hooks (e.g., ERC-777).
   - **Trust Boundary:** External contracts. Token contract behavior must conform to OpenZeppelin `SafeERC20`.
3. **Protocol Owner (`onlyOwner`):**
   - **Assumption:** Admin private key is secured (multisig / timelock recommended for production).
   - **Trust Boundary:** Highly privileged role capable of setting LTV, liquidation thresholds, and interest models.
4. **Liquidators & Flash Loan Arbitrageurs:**
   - **Assumption:** Untrusted actors motivated by economic profit.
   - **Trust Boundary:** Can call `liquidate()` and `flashLoan()` atomically.

---

## 2. System Assets & Accounting Mechanics

### Share-Based Vault Accounting
- **Collateral:** Assets supplied to the pool mint internal collateral shares (`userCollateralShares`).
  $$\text{Shares Minted} = \begin{cases} \text{amount}, & \text{if } \text{totalShares} = 0 \text{ or } \text{totalAmount} = 0 \\ \lfloor \frac{\text{amount} \times \text{totalShares}}{\text{totalAmount}} \rfloor, & \text{otherwise} \end{cases}$$
- **Debt & Interest Accrual:** Debt is tracked via `userDebtShares` and scaled by a global `borrowIndex` (initialized to $1.0 = 10^{18}$).
  $$\text{User Debt Amount} = \lfloor \frac{\text{userDebtShares} \times \text{borrowIndex}}{10^{18}} \rfloor$$
  $$\text{borrowIndex}_{new} = \lfloor \frac{\text{borrowIndex}_{old} \times (10^{18} + \text{interestFactor})}{10^{18}} \rfloor$$
  where $\text{interestFactor} = \frac{\text{borrowRate} \times \Delta t}{365 \text{ days}}$.

---

## 3. Threat Vectors & Vulnerability Analysis

| Threat ID | Threat Category | Impact | Likelihood | Mitigation in Codebase |
|---|---|---|---|---|
| **T-01** | **Oracle Manipulation / Stale Price** | High | Medium | `require(oracle.isFresh(asset), "STALE_PRICE")` enforced before all valuation operations. |
| **T-02** | **First Deposit Share Inflation Attack** | Medium | Low | Initial deposit mints 1:1 shares. `withdraw()` rounds up shares burned (`(amount * totalShares + totalAmount - 1) / totalAmount`) to favor protocol solvency. |
| **T-03** | **Undercollateralized Borrowing / Solvency Breach** | High | Low | `getUserAccountData()` evaluates weighted LTV and Health Factor ($HF \ge 1.0$). Strict revert in `borrow()` and `withdraw()`. |
| **T-04** | **Reentrancy via Token Callbacks** | High | Medium | All state-changing functions (`deposit`, `withdraw`, `borrow`, `repay`, `flashLoan`) use `nonReentrant` modifier from OpenZeppelin `ReentrancyGuard`. |
| **T-05** | **Liquidation Front-Running & Dust Debt** | Medium | Low | Close factor capped at 50% (`maxDebtToCover = userDebtAmount / 2`). Small remaining debt allowed full close to prevent dust positions. |
| **T-06** | **Flash Loan Asset Drain / Reentrancy** | High | Low | Pool checks post-execution balance via `IERC20.safeTransferFrom` and enforces 0.09% fee (`premium`). `nonReentrant` prevents re-entering pool during flash loan callback. |
| **T-07** | **Bad Debt Socialization Failure** | High | Medium | *Open Design Choice.* If collateral value drops faster than liquidators can act, bad debt remains unhandled. |
| **T-08** | **Admin Governance Misconfiguration** | High | Low | `setAssetConfig` checks `ltv <= liquidationThreshold` and `liquidationThreshold <= 10000`. Restricted to `onlyOwner`. |

---

## 4. Safety Invariants

The protocol guarantees the following strict invariant properties:

1. **Solvency Invariant:**
   $$\forall \text{user } u \text{ with } \text{totalDebtUSD}(u) > 0 \implies \text{HealthFactor}(u) = \frac{\text{totalCollateralUSD}(u) \times \text{liquidationThreshold}(u)}{\text{totalDebtUSD}(u)} \ge 1.0$$
2. **Debt Monotonicity Invariant:**
   $$t_2 \ge t_1 \implies \text{borrowIndex}_{t_2}(A) \ge \text{borrowIndex}_{t_1}(A)$$
3. **Share Conservation Invariant:**
   $$\sum_{u} \text{userCollateralShares}(A, u) = \text{totalCollateralShares}(A)$$
   $$\sum_{u} \text{userDebtShares}(A, u) = \text{totalDebtShares}(A)$$
4. **Liquidation Protection Invariant:**
   $$\text{Account } u \text{ can be liquidated} \iff \text{HealthFactor}(u) < 1.0 \times 10^{18}$$
5. **Flash Loan Capital Preservation:**
   $$\text{balanceOf}(\text{pool})_{after} \ge \text{balanceOf}(\text{pool})_{before} + \text{premium}$$

---

## 5. Unresolved Security Risks & Recommendations

1. **Bad Debt Socialization:** Currently, if position debt exceeds collateral value during market crash ($HF < 1.0$ and debt USD > collateral USD), liquidating the position leaves unbacked bad debt in `totalDebtShares`. A reserve pool or debt write-off mechanism should be introduced in Milestone 3.
2. **Interest Accrual Compounding vs Linear:** Interest uses linear accrual per block timestamp. While simpler, compounding behavior over long inactive periods should be analyzed against yield drift.
3. **Oracle Stale Window:** The exact staleness threshold is delegated to `IVigilendOracle.isFresh()`. Mock and production implementations must strictly enforce heartbeat checks (e.g. Chainlink staleness checks `updatedAt < block.timestamp - MAX_DELAY`).
