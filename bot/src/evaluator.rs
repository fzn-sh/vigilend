use crate::types::UserAccountSummary;
use ethers::types::U256;

pub struct Evaluator;

impl Evaluator {
    /// Calculate estimated profit in USD (18 decimals) for liquidating debt_to_cover with a bonus (bps)
    pub fn estimate_profit_usd(
        debt_to_cover_usd: U256,
        bonus_bps: u64,
        estimated_gas_cost_usd: U256,
    ) -> U256 {
        // Bonus profit = debt_to_cover_usd * bonus_bps / 10,000
        let bonus_amount = (debt_to_cover_usd * U256::from(bonus_bps)) / U256::from(10000);

        if bonus_amount > estimated_gas_cost_usd {
            bonus_amount - estimated_gas_cost_usd
        } else {
            U256::zero()
        }
    }

    /// Check if target is profitable based on minimum required profit threshold
    pub fn is_profitable(
        account: &UserAccountSummary,
        estimated_profit_usd: U256,
        min_profit_usd: U256,
    ) -> bool {
        account.is_liquidatable()
            && !account.total_collateral_usd.is_zero()
            && estimated_profit_usd >= min_profit_usd
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ethers::types::Address;

    #[test]
    fn test_liquidatable_account_detection() {
        let healthy_account = UserAccountSummary {
            user: Address::zero(),
            total_collateral_usd: U256::from(1000),
            total_debt_usd: U256::from(500),
            available_borrows_usd: U256::from(250),
            current_liquidation_threshold: U256::from(8000),
            ltv: U256::from(7500),
            health_factor: U256::from(1_500_000_000_000_000_000u64), // 1.5
        };
        assert!(!healthy_account.is_liquidatable());

        let distressed_account = UserAccountSummary {
            user: Address::zero(),
            total_collateral_usd: U256::from(1000),
            total_debt_usd: U256::from(900),
            available_borrows_usd: U256::zero(),
            current_liquidation_threshold: U256::from(8000),
            ltv: U256::from(7500),
            health_factor: U256::from(888_888_888_888_888_888u64), // 0.888 (< 1.0)
        };
        assert!(distressed_account.is_liquidatable());
    }

    #[test]
    fn test_profitability_calculation() {
        let debt_usd = U256::from(1_000_000_000_000_000_000u128 * 1000); // $1000 USD
        let bonus_bps = 500; // 5% bonus ($50 USD)
        let gas_cost = U256::from(1_000_000_000_000_000_000u128 * 10); // $10 USD gas

        let profit = Evaluator::estimate_profit_usd(debt_usd, bonus_bps, gas_cost);
        assert_eq!(profit, U256::from(1_000_000_000_000_000_000u128 * 40)); // $40 USD net profit
    }
}
