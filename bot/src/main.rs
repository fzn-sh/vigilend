use ethers::providers::{Http, Provider};
use ethers::types::U256;
use eyre::Result;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::sleep;
use tracing::{error, info, warn};

use vigilend_bot::{AccountMonitor, Config, Evaluator, LiquidationExecutor, LiquidationTarget};

fn format_units_18(val: U256) -> String {
    let f = val.as_u128() as f64 / 1e18;
    format!("{:.4}", f)
}

fn format_usd(val: U256) -> String {
    let f = val.as_u128() as f64 / 1e18;
    format!("${:.2}", f)
}

fn format_usdc(val: U256) -> String {
    let f = val.as_u128() as f64 / 1e6;
    format!("${:.2} USDC", f)
}

fn format_weth(val: U256) -> String {
    let f = val.as_u128() as f64 / 1e18;
    format!("{:.4} WETH", f)
}

#[tokio::main]
async fn main() -> Result<()> {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_target(false)
        .init();

    info!("⚡ ========================================================== ⚡");
    info!("🛡️  VIGILEND HIGH-FREQUENCY LIQUIDATION BOT SERVICE ACTIVE  🛡️");
    info!("⚡ ========================================================== ⚡");

    let config = Config::from_env()?;
    info!(
        rpc = %config.rpc_url,
        pool = ?config.pool_address,
        oracle = ?config.oracle_address,
        weth = ?config.weth_address,
        usdc = ?config.usdc_address,
        liquidator = ?config.bot_address,
        min_profit = %format!("${}.00", config.min_profit_usd),
        "⚙️  Configuration Initialized"
    );

    let provider = match Provider::<Http>::try_from(&config.rpc_url) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            error!(error = %e, "❌ Failed to connect to RPC Provider");
            return Err(e.into());
        }
    };

    let mut monitor = AccountMonitor::new(config.pool_address);
    let executor = LiquidationExecutor::new(config.pool_address);

    info!("📡 Monitoring loop online. Scanning on-chain events every 5s...");

    loop {
        // Scan RPC Node for active Borrow events
        if let Err(err) = monitor.scan_new_borrowers(provider.clone(), 0).await {
            warn!(error = %err, "⚠️ Failed to scan new borrowers from RPC");
        }

        let tracked_users = monitor.tracked_users.clone();

        for user in tracked_users {
            match monitor.fetch_account_summary(provider.clone(), user).await {
                Ok(summary) => {
                    let hf_str = format_units_18(summary.health_factor);
                    let col_str = format_usd(summary.total_collateral_usd);
                    let debt_str = format_usd(summary.total_debt_usd);

                    info!(
                        borrower = ?user,
                        HF = %hf_str,
                        collateral = %col_str,
                        debt = %debt_str,
                        "🔍 Monitored Borrower Position Check"
                    );

                    if summary.is_liquidatable() {
                        warn!(
                            borrower = ?user,
                            HF = %hf_str,
                            collateral = %col_str,
                            debt = %debt_str,
                            "🚨 DISTRESSED BORROWER DETECTED (HF < 1.0)!"
                        );

                        // Convert total_debt_usd (18 decimals) to debt_token amount (6 decimals for USDC)
                        let debt_token_amount =
                            summary.total_debt_usd / U256::from(1_000_000_000_000u64); // 18 -> 6 decimals
                        let debt_to_cover = debt_token_amount / U256::from(2); // Close factor 50%

                        let target = LiquidationTarget {
                            borrower: user,
                            collateral_asset: config.weth_address,
                            debt_asset: config.usdc_address,
                            debt_to_cover,
                            estimated_profit_usd: U256::from(config.min_profit_usd * 10),
                        };

                        if Evaluator::is_profitable(
                            &summary,
                            target.estimated_profit_usd,
                            U256::from(config.min_profit_usd),
                        ) {
                            let cover_str = format_usdc(target.debt_to_cover);
                            info!(
                                borrower = ?user,
                                debt_to_cover = %cover_str,
                                "🎯 Target Profitable. Executing eth_call Liquidation Simulation..."
                            );

                            match executor
                                .simulate_liquidation(provider.clone(), &target, config.bot_address)
                                .await
                            {
                                Ok(seized) => {
                                    let seized_str = format_weth(seized);
                                    info!(
                                        borrower = ?user,
                                        seized_collateral = %seized_str,
                                        "✅ LIQUIDATION SIMULATION PASSED! PROFITABLE TARGET ACQUIRED 🎉"
                                    );
                                }
                                Err(err) => {
                                    error!(error = %err, "❌ Liquidation simulation failed / reverted.");
                                }
                            }
                        }
                    }
                }
                Err(err) => {
                    warn!(user = ?user, error = %err, "⚠️ Failed to fetch account summary for user");
                }
            }
        }

        sleep(Duration::from_secs(5)).await;
    }
}
