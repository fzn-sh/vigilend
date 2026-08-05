use ethers::contract::abigen;
use ethers::providers::{Http, Provider};
use ethers::types::Address;
use eyre::{Result, WrapErr};
use std::collections::HashSet;
use std::sync::Arc;
use tracing::info;

use crate::types::UserAccountSummary;

abigen!(
    VigilendPoolContract,
    r#"[
        function getUserAccountData(address user) external view returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 availableBorrowsUSD, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor)
        function liquidate(address collateralAsset, address debtAsset, address borrower, uint256 debtToCover) external returns (uint256)
        function flashLoan(address receiverAddress, address asset, uint256 amount, bytes params) external
        event Deposit(address indexed asset, address indexed caller, address indexed onBehalfOf, uint256 amount, uint256 shares)
        event Borrow(address indexed asset, address indexed caller, address indexed onBehalfOf, uint256 amount)
        event Liquidate(address indexed collateralAsset, address indexed debtAsset, address indexed borrower, address liquidator, uint256 debtToCover, uint256 liquidatedCollateral)
        event FlashLoan(address indexed target, address indexed initiator, address indexed asset, uint256 amount, uint256 premium)
    ]"#
);

pub struct AccountMonitor {
    pub pool_address: Address,
    pub tracked_users: HashSet<Address>,
}

impl AccountMonitor {
    pub fn new(pool_address: Address) -> Self {
        Self {
            pool_address,
            tracked_users: HashSet::new(),
        }
    }

    pub fn register_user(&mut self, user: Address) -> bool {
        if user != Address::zero() && self.tracked_users.insert(user) {
            info!(user = ?user, "Registered new active borrower for monitoring");
            true
        } else {
            false
        }
    }

    pub fn tracked_count(&self) -> usize {
        self.tracked_users.len()
    }

    /// Query Borrow events on-chain to discover active borrowers
    pub async fn scan_new_borrowers(
        &mut self,
        provider: Arc<Provider<Http>>,
        from_block: u64,
    ) -> Result<usize> {
        let contract = VigilendPoolContract::new(self.pool_address, provider);
        let borrow_events = contract
            .borrow_filter()
            .from_block(from_block)
            .query()
            .await
            .wrap_err("Failed to query Borrow events from RPC")?;

        let mut new_count = 0;
        for event in borrow_events {
            if self.register_user(event.on_behalf_of) {
                new_count += 1;
            }
        }
        Ok(new_count)
    }

    pub async fn fetch_account_summary(
        &self,
        provider: Arc<Provider<Http>>,
        user: Address,
    ) -> Result<UserAccountSummary> {
        let contract = VigilendPoolContract::new(self.pool_address, provider);

        let (
            total_collateral_usd,
            total_debt_usd,
            available_borrows_usd,
            current_liquidation_threshold,
            ltv,
            health_factor,
        ) = contract
            .get_user_account_data(user)
            .call()
            .await
            .wrap_err("Failed to fetch user account data from RPC")?;

        Ok(UserAccountSummary {
            user,
            total_collateral_usd,
            total_debt_usd,
            available_borrows_usd,
            current_liquidation_threshold,
            ltv,
            health_factor,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_register_user_deduplication() {
        let mut monitor = AccountMonitor::new(Address::zero());
        let user1 = Address::repeat_byte(0x1);
        let user2 = Address::repeat_byte(0x2);

        assert!(monitor.register_user(user1));
        assert!(!monitor.register_user(user1)); // Duplicate
        assert!(monitor.register_user(user2));

        assert_eq!(monitor.tracked_count(), 2);
    }
}
