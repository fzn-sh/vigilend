use ethers::types::{Address, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UserAccountSummary {
    pub user: Address,
    pub total_collateral_usd: U256,
    pub total_debt_usd: U256,
    pub available_borrows_usd: U256,
    pub current_liquidation_threshold: U256,
    pub ltv: U256,
    pub health_factor: U256,
}

impl UserAccountSummary {
    pub fn is_liquidatable(&self) -> bool {
        // Health Factor < 1.0 (1e18)
        self.health_factor < U256::from(1_000_000_000_000_000_000u64)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidationTarget {
    pub borrower: Address,
    pub collateral_asset: Address,
    pub debt_asset: Address,
    pub debt_to_cover: U256,
    pub estimated_profit_usd: U256,
}
