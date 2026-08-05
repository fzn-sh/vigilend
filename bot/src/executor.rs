use ethers::providers::{Http, Middleware, Provider};
use ethers::types::{Address, Bytes, TransactionRequest, U256};
use eyre::{Result, WrapErr};
use std::sync::Arc;
use tracing::info;

use crate::listener::VigilendPoolContract;
use crate::types::LiquidationTarget;

pub struct LiquidationExecutor {
    pub pool_address: Address,
}

impl LiquidationExecutor {
    pub fn new(pool_address: Address) -> Self {
        Self { pool_address }
    }

    /// Build transaction call data for liquidate(collateralAsset, debtAsset, borrower, debtToCover)
    pub fn encode_liquidate_calldata(&self, target: &LiquidationTarget) -> Bytes {
        let contract = VigilendPoolContract::new(
            self.pool_address,
            Arc::new(Provider::<Http>::try_from("http://127.0.0.1:8545").unwrap()),
        );
        let call = contract.liquidate(
            target.collateral_asset,
            target.debt_asset,
            target.borrower,
            target.debt_to_cover,
        );
        call.calldata().unwrap_or_default()
    }

    /// Simulate liquidation transaction via eth_call before submission
    pub async fn simulate_liquidation(
        &self,
        provider: Arc<Provider<Http>>,
        target: &LiquidationTarget,
        sender: Address,
    ) -> Result<U256> {
        let calldata = self.encode_liquidate_calldata(target);

        let tx = TransactionRequest::new()
            .to(self.pool_address)
            .from(sender)
            .data(calldata);

        let result_bytes = provider
            .call(&tx.into(), None)
            .await
            .wrap_err("Liquidation simulation (eth_call) failed / reverted")?;

        let seized_collateral = U256::from_big_endian(&result_bytes);
        info!(
            borrower = ?target.borrower,
            seized_collateral = %seized_collateral,
            "Liquidation simulation succeeded"
        );

        Ok(seized_collateral)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_liquidate_calldata() {
        let executor = LiquidationExecutor::new(Address::zero());
        let target = LiquidationTarget {
            borrower: Address::repeat_byte(0x1),
            collateral_asset: Address::repeat_byte(0x2),
            debt_asset: Address::repeat_byte(0x3),
            debt_to_cover: U256::from(1000),
            estimated_profit_usd: U256::from(50),
        };

        let calldata = executor.encode_liquidate_calldata(&target);
        assert!(!calldata.is_empty());
    }
}
