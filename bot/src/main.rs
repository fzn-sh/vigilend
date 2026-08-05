use eyre::Result;
use tracing::info;
use vigilend_bot::Config;

#[tokio::main]
async fn main() -> Result<()> {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    tracing_subscriber::fmt().with_env_filter(env_filter).init();

    info!("Starting Vigilend Liquidation Bot...");

    let config = Config::from_env()?;
    info!(
        rpc_url = %config.rpc_url,
        pool = ?config.pool_address,
        oracle = ?config.oracle_address,
        min_profit = config.min_profit_usd,
        "Configuration initialized"
    );

    info!("Liquidation Bot monitoring loop initialized successfully.");
    Ok(())
}
