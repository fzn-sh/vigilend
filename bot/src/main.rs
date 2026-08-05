use ethers::providers::{Http, Provider};
use ethers::types::U256;
use eyre::Result;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::sleep;
use tracing::{debug, error, info, warn};

use vigilend_bot::{AccountMonitor, Config, Evaluator, LiquidationExecutor, LiquidationTarget};

// ANSI Color Escape Constants for Quant Dashboard
const C_RESET: &str = "\x1b[0m";
const C_BOLD: &str = "\x1b[1m";
const C_RED: &str = "\x1b[31m";
const C_GREEN: &str = "\x1b[32m";
const C_CYAN: &str = "\x1b[36m";

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
    format!("{:.2} USDC", f)
}

fn format_weth(val: U256) -> String {
    let f = val.as_u128() as f64 / 1e18;
    format!("{:.4} WETH", f)
}

fn print_row_colored(label: &str, val: &str, color: &str) {
    let padded_val = format!("{:<54}", val);
    println!("│ {:<18}: {}{}{} │", label, color, padded_val, C_RESET);
}

fn print_row(label: &str, val: &str) {
    print_row_colored(label, val, "");
}

#[tokio::main]
async fn main() -> Result<()> {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_target(false)
        .init();

    println!("┌────────────────────────────────────────────────────────────────────────────┐");
    println!(
        "│ {}{}⚡ VIGILEND HIGH-FREQUENCY QUANT LIQUIDATION ENGINE v0.1.0 (LIVE){}    │",
        C_BOLD, C_CYAN, C_RESET
    );
    println!("└────────────────────────────────────────────────────────────────────────────┘");

    let config = Config::from_env()?;
    info!(
        rpc = %config.rpc_url,
        pool = ?config.pool_address,
        oracle = ?config.oracle_address,
        weth = ?config.weth_address,
        usdc = ?config.usdc_address,
        liquidator = ?config.bot_address,
        flash_receiver = ?config.flash_receiver_address,
        use_flash_loan = config.use_flash_loan,
        simulation_only = config.simulation_only,
        min_profit = %format!("${:.2}", config.min_profit_usd as f64),
        "⚙️  Quant Engine Parameters Initialized"
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

    info!("📡 Order Routing Active. Polling EVM state every 5s...");

    let private_key = config.private_key.unwrap_or_else(|| {
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80".to_string()
    });

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

                    debug!(
                        borrower = ?user,
                        HF = %hf_str,
                        collateral = %col_str,
                        debt = %debt_str,
                        "📊 Position Telemetry Check"
                    );

                    if summary.is_liquidatable() {
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
                            let hf_status = format!("{} [STATUS: CRITICAL < 1.0000]", hf_str);

                            println!("┌─ [TARGET ACQUIRED: DISTRESSED BORROWER] ───────────────────────────────────┐");
                            print_row("Borrower Address", &format!("{:?}", user));
                            print_row("Collateral Value", &col_str);
                            print_row("Total Debt Value", &debt_str);
                            print_row_colored("Health Factor", &hf_status, C_RED);
                            println!("├─ [EXECUTION ROUTING] ──────────────────────────────────────────────────────┤");

                            let cover_str = format_usdc(target.debt_to_cover);
                            let strategy_str = if config.use_flash_loan {
                                "WETH <==> USDC [CAPITAL-FREE FLASH LOAN]"
                            } else {
                                "WETH <==> USDC [DIRECT CAPITAL]"
                            };
                            print_row("Pair Strategy", strategy_str);
                            print_row("Debt Repay Amount", &cover_str);
                            print_row("Incentive Bonus", "+5.00% Liquidation Premium");

                            match executor
                                .simulate_liquidation(provider.clone(), &target, config.bot_address)
                                .await
                            {
                                Ok(seized) => {
                                    let seized_str = format_weth(seized);
                                    print_row_colored(
                                        "Simulation Result",
                                        "eth_call SUCCESSFUL [OK]",
                                        C_GREEN,
                                    );
                                    print_row("Seized Collateral", &seized_str);

                                    if !config.simulation_only {
                                        print_row(
                                            "On-Chain Status",
                                            "Broadcasting Tx to EVM Mempool...",
                                        );
                                        match executor
                                            .execute_liquidation(
                                                provider.clone(),
                                                &target,
                                                &private_key,
                                                config.use_flash_loan,
                                                config.flash_receiver_address,
                                            )
                                            .await
                                        {
                                            Ok(receipt) => {
                                                let raw_hash =
                                                    format!("{:?}", receipt.transaction_hash);
                                                let short_hash = if raw_hash.len() > 24 {
                                                    format!(
                                                        "{}...{}",
                                                        &raw_hash[..10],
                                                        &raw_hash[raw_hash.len() - 8..]
                                                    )
                                                } else {
                                                    raw_hash
                                                };

                                                let block_str = format!(
                                                    "{:?}",
                                                    receipt.block_number.unwrap_or_default()
                                                );
                                                let live_res =
                                                    format!("CONFIRMED (Block #{})", block_str);
                                                print_row_colored(
                                                    "Execution Result",
                                                    &live_res,
                                                    C_GREEN,
                                                );
                                                print_row("Transaction Hash", &short_hash);
                                            }
                                            Err(err) => {
                                                let err_str = format!("FAILED ({:?})", err);
                                                print_row_colored(
                                                    "Execution Result",
                                                    &err_str,
                                                    C_RED,
                                                );
                                            }
                                        }
                                    }

                                    println!("└────────────────────────────────────────────────────────────────────────────┘");
                                }
                                Err(err) => {
                                    let err_str = format!("REVERTED [ERR: {:?}]", err);
                                    print_row_colored("Simulation Result", &err_str, C_RED);
                                    println!("└────────────────────────────────────────────────────────────────────────────┘");
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
