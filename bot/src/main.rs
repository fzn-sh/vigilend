use ethers::providers::{Http, Provider};
use ethers::types::U256;
use eyre::Result;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::sleep;
use tracing::{error, info, warn};

use vigilend_bot::{AccountMonitor, Config, Evaluator, LiquidationExecutor, LiquidationTarget};

#[tokio::main]
async fn main() -> Result<()> {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    tracing_subscriber::fmt().with_env_filter(env_filter).init();

    info!("Starting Vigilend Liquidation Bot Service...");

    let config = Config::from_env()?;
    info!(
        rpc_url = %config.rpc_url,
        pool = ?config.pool_address,
        oracle = ?config.oracle_address,
        min_profit_usd = config.min_profit_usd,
        "Configuration initialized"
    );

    let provider = match Provider::<Http>::try_from(&config.rpc_url) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            error!(error = %e, "Failed to connect to RPC Provider");
            return Err(e.into());
        }
    };

    let monitor = AccountMonitor::new(config.pool_address);
    let executor = LiquidationExecutor::new(config.pool_address);

    info!("Liquidation Service active. Starting position monitoring loop...");

    loop {
        let tracked_users = monitor.tracked_users.clone();

        for user in tracked_users {
            match monitor.fetch_account_summary(provider.clone(), user).await {
                Ok(summary) => {
                    if summary.is_liquidatable() {
                        warn!(
                            user = ?user,
                            health_factor = %summary.health_factor,
                            total_debt_usd = %summary.total_debt_usd,
                            "Distressed borrower position detected!"
                        );

                        let target = LiquidationTarget {
                            borrower: user,
                            collateral_asset: config.oracle_address, // Default target collateral asset
                            debt_asset: config.pool_address,         // Default target debt asset
                            debt_to_cover: summary.total_debt_usd / U256::from(2),
                            estimated_profit_usd: U256::from(config.min_profit_usd * 10),
                        };

                        if Evaluator::is_profitable(
                            &summary,
                            target.estimated_profit_usd,
                            U256::from(config.min_profit_usd),
                        ) {
                            info!(target = ?target, "Target is profitable. Simulating liquidation via eth_call...");

                            match executor
                                .simulate_liquidation(
                                    provider.clone(),
                                    &target,
                                    config.pool_address,
                                )
                                .await
                            {
                                Ok(seized) => {
                                    info!(seized_collateral = %seized, "Liquidation simulation passed successfully.");
                                }
                                Err(err) => {
                                    error!(error = %err, "Liquidation simulation failed/reverted.");
                                }
                            }
                        }
                    }
                }
                Err(err) => {
                    warn!(user = ?user, error = %err, "Failed to fetch account summary for user");
                }
            }
        }

        sleep(Duration::from_secs(12)).await;
    }
}
