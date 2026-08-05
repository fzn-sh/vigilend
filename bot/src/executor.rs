use ethers::middleware::SignerMiddleware;
use ethers::providers::{Http, Middleware, Provider};
use ethers::signers::{LocalWallet, Signer};
use ethers::types::transaction::eip2718::TypedTransaction;
use ethers::types::{Address, Bytes, TransactionReceipt, TransactionRequest, U256};
use eyre::{Result, WrapErr};
use std::sync::Arc;
use tracing::debug;

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

    /// Simulate liquidation transaction using eth_call
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

        let typed_tx: TypedTransaction = tx.into();

        let return_bytes = provider
            .call(&typed_tx, None)
            .await
            .wrap_err("Liquidation simulation (eth_call) failed / reverted")?;

        if return_bytes.is_empty() {
            eyre::bail!("Liquidation simulation returned empty bytes");
        }

        let seized_collateral = U256::from_big_endian(&return_bytes);
        debug!(
            borrower = ?target.borrower,
            seized_collateral = %seized_collateral,
            "Liquidation simulation succeeded"
        );

        Ok(seized_collateral)
    }

    /// Execute real liquidation transaction on-chain signed with private key
    pub async fn execute_liquidation(
        &self,
        provider: Arc<Provider<Http>>,
        target: &LiquidationTarget,
        private_key: &str,
    ) -> Result<TransactionReceipt> {
        let wallet: LocalWallet = private_key
            .parse::<LocalWallet>()
            .wrap_err("Invalid private key format")?
            .with_chain_id(31337u64);

        let client = SignerMiddleware::new(provider, wallet);
        let calldata = self.encode_liquidate_calldata(target);

        let tx = TransactionRequest::new()
            .to(self.pool_address)
            .data(calldata);

        let pending_tx = client
            .send_transaction(tx, None)
            .await
            .wrap_err("Failed to broadcast liquidation transaction")?;

        let receipt = pending_tx
            .await
            .wrap_err("Failed while waiting for transaction receipt")?
            .ok_or_else(|| eyre::eyre!("Transaction dropped from mempool"))?;

        Ok(receipt)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_liquidate_calldata() {
        let executor = LiquidationExecutor::new(Address::zero());
        let target = LiquidationTarget {
            borrower: Address::zero(),
            collateral_asset: Address::zero(),
            debt_asset: Address::zero(),
            debt_to_cover: U256::from(100),
            estimated_profit_usd: U256::from(10),
        };

        let calldata = executor.encode_liquidate_calldata(&target);
        assert!(!calldata.is_empty());
        assert_eq!(&calldata[0..4], &[0xaa, 0xb3, 0xf8, 0x68]); // liquidate selector
    }
}
