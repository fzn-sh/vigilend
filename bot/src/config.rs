use ethers::types::Address;
use eyre::{Result, WrapErr};
use std::env;
use std::str::FromStr;

#[derive(Debug, Clone)]
pub struct Config {
    pub rpc_url: String,
    pub pool_address: Address,
    pub oracle_address: Address,
    pub weth_address: Address,
    pub usdc_address: Address,
    pub bot_address: Address,
    pub min_profit_usd: u64,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        dotenvy::dotenv().ok();

        let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string());

        let pool_str = env::var("POOL_ADDRESS")
            .unwrap_or_else(|_| "0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0".to_string());
        let pool_address = Address::from_str(&pool_str).wrap_err("Invalid POOL_ADDRESS format")?;

        let oracle_str = env::var("ORACLE_ADDRESS")
            .unwrap_or_else(|_| "0x5fbdb2315678afecb367f032d93f642f64180aa3".to_string());
        let oracle_address =
            Address::from_str(&oracle_str).wrap_err("Invalid ORACLE_ADDRESS format")?;

        let weth_str = env::var("WETH_ADDRESS")
            .unwrap_or_else(|_| "0xcf7ed3acca5a467e9e704c703e8d87f634fb0fc9".to_string());
        let weth_address = Address::from_str(&weth_str).wrap_err("Invalid WETH_ADDRESS format")?;

        let usdc_str = env::var("USDC_ADDRESS")
            .unwrap_or_else(|_| "0xdc64a140aa3e981100a9beca4e685f962f0cf6c9".to_string());
        let usdc_address = Address::from_str(&usdc_str).wrap_err("Invalid USDC_ADDRESS format")?;

        let bot_str = env::var("BOT_ADDRESS")
            .unwrap_or_else(|_| "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266".to_string());
        let bot_address = Address::from_str(&bot_str).wrap_err("Invalid BOT_ADDRESS format")?;

        let min_profit_usd = env::var("MIN_PROFIT_USD")
            .unwrap_or_else(|_| "10".to_string())
            .parse::<u64>()
            .unwrap_or(10);

        Ok(Self {
            rpc_url,
            pool_address,
            oracle_address,
            weth_address,
            usdc_address,
            bot_address,
            min_profit_usd,
        })
    }
}
