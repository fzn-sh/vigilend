use ethers::types::Address;
use eyre::{Result, WrapErr};
use std::env;
use std::str::FromStr;

#[derive(Debug, Clone)]
pub struct Config {
    pub rpc_url: String,
    pub pool_address: Address,
    pub oracle_address: Address,
    pub min_profit_usd: u64,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        dotenvy::dotenv().ok();

        let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string());

        let pool_str = env::var("POOL_ADDRESS")
            .unwrap_or_else(|_| "0x0000000000000000000000000000000000000000".to_string());
        let pool_address = Address::from_str(&pool_str).wrap_err("Invalid POOL_ADDRESS format")?;

        let oracle_str = env::var("ORACLE_ADDRESS")
            .unwrap_or_else(|_| "0x0000000000000000000000000000000000000000".to_string());
        let oracle_address =
            Address::from_str(&oracle_str).wrap_err("Invalid ORACLE_ADDRESS format")?;

        let min_profit_usd = env::var("MIN_PROFIT_USD")
            .unwrap_or_else(|_| "10".to_string())
            .parse::<u64>()
            .unwrap_or(10);

        Ok(Self {
            rpc_url,
            pool_address,
            oracle_address,
            min_profit_usd,
        })
    }
}
