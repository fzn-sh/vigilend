# Vigilend — EVM Lending Protocol & MEV Liquidation Bot

Vigilend is a safety-critical, modular, overcollateralized lending protocol composed of:
1. **Solidity Protocol Core (`src/`)**: High-performance lending pool, dynamic variable interest rate model, price oracle adapters, and capital-free Flash Loans.
2. **Rust Liquidation Engine (`bot/`)**: High-frequency, async Tokio-based EVM off-chain searcher service with multi-strategy routing (Direct Capital vs Capital-Free Flash Loans), real-time RPC event scanning, bad debt filtering, and zero-downtime `.env` hot-reloading.
3. **Automated Market Simulator (`simulate.sh`)**: End-to-end stress testing tool simulating dynamic borrower deposits, randomized USDC debt, and Oracle price crashes.

---

## 🏛️ Protocol Architecture & Key Mechanics

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            VIGILEND PROTOCOL CORE                           │
├──────────────────────────────┬──────────────────────────────┬───────────────┤
│ VigilendPool.sol             │ InterestRateModel.sol        │ MockOracle.sol│
│ - Deposit & Share Accounting │ - Jump Rate Model (Kinked)   │ - Price Feeds │
│ - Collateralized Borrowing   │ - Variable Borrow APY        │ - Stale Check │
│ - Flash Loans (0.09% Fee)    │ - Supply APY Curve           │               │
└──────────────▲───────────────┴──────────────▲───────────────┴───────────────┘
               │                              │
               │  eth_call / Mempool Tx       │ Flash Loan Callback
               │                              │
┌──────────────┴──────────────────────────────┴───────────────────────────────┐
│                      RUST LIQUIDATION ENGINE (bot/)                         │
├──────────────────────────────┬──────────────────────────────┬───────────────┤
│ listener.rs                  │ evaluator.rs                 │ executor.rs   │
│ - EVM Log Event Filter       │ - Profitability Check        │ - Signer MW   │
│ - Account Health Monitor     │ - Underwater Bad Debt Filter │ - Hot-Reload  │
└──────────────────────────────┴──────────────────────────────┴───────────────┘
```

### 1. Risk & Accounting Parameters
- **Loan-to-Value (LTV)**: 75% for WETH, 85% for USDC.
- **Liquidation Threshold**: 80% for WETH, 90% for USDC.
- **Liquidation Penalty / Premium**: 5.0% incentive bonus awarded to liquidator.
- **Close Factor**: 50% max debt repayment per liquidation transaction.
- **Flash Loan Fee**: 0.09% (9 bps) charged on principal.

### 2. High-Frequency Rust Liquidation Subsystem
- **Zero-Capital Flash Loan Routing**: Uses `FlashLiquidationReceiver.sol` to atomically borrow USDC from the pool, liquidate distressed positions, seize collateral WETH, and return flash loan principal + fee in a single block.
- **Smart Underwater Bad Debt Filtering**: Evaluates `total_collateral_usd > debt_to_cover_usd` before submitting transactions to prevent net-loss liquidations on insolvent accounts.
- **Zero-Downtime Hot-Reloading**: Automatically detects disk edits to `bot/.env` (e.g. toggling `USE_FLASH_LOAN=true/false`) on the fly without stopping the `cargo run` process.
- **Quant HFT ASCII Dashboard**: Renders 78-character aligned, colorized CLI telemetry reporting Health Factor, Strategy Route, Debt Repaid, Flash Fee, and confirmed Tx Hashes.

---

## 🛠️ Verification & Test Suite

The protocol and liquidation engine are verified using Foundry unit/fuzz/stateful invariant tests and Cargo clippy/fmt checks:

| Subsystem | Purpose | Command |
|---|---|---|
| **Solidity Build** | Compile all contracts & interfaces | `forge build` |
| **Unit & Fuzz Tests** | Execute unit and 1000-run fuzz tests | `forge test` |
| **Stateful Invariant Tests** | Run 25,600-call solvency invariant checks | `forge test --match-path test/invariant/**` |
| **Solidity Formatting** | Check code formatting adherence | `forge fmt --check` |
| **Rust Tests** | Test bot logic, encoders, and evaluator | `cargo test` |
| **Rust Clippy Lint** | Strict zero-warning linting | `cargo clippy -- -D warnings` |
| **Rust Formatting** | Verify Rust formatting | `cargo fmt --check` |

---

## 🚀 Quickstart & Local Execution

### 1. Prerequisites
- [Foundry (`forge`, `cast`, `anvil`)](https://getfoundry.sh/)
- [Rust Toolchain (1.70+)](https://rustup.rs/)

### 2. Start Local Anvil EVM Node
In Terminal 1:
```bash
anvil
```

### 3. Deploy Protocol Contracts
In Terminal 2:
```bash
forge script script/Deploy.s.sol --fork-url http://127.0.0.1:8545 --broadcast
```

### 4. Launch Rust Liquidation Engine
In Terminal 3 (navigate to `bot/`):
```bash
cd bot
cargo run
```

### 5. Run Market Simulation Traffic
In Terminal 4:
```bash
./simulate.sh --loop
```

Watch Terminal 3! The Rust Liquidation Bot will monitor EVM state 24/7, acquire distressed targets, and execute signed on-chain transactions with pixel-perfect Quant CLI output!

---

## 🎛️ Configuration (`bot/.env`)

| Environment Variable | Description | Default |
|---|---|---|
| `RPC_URL` | EVM JSON-RPC provider URL | `http://127.0.0.1:8545` |
| `POOL_ADDRESS` | Address of `VigilendPool` contract | `0x9fd16ea9e31233279975d99d5e8fc91dd214c7da` |
| `ORACLE_ADDRESS` | Address of `MockOracle` contract | `0xd3ffd73c53f139cebb80b6a524be280955b3f4db` |
| `FLASH_RECEIVER_ADDRESS` | Address of `FlashLiquidationReceiver` | `0xb932c8342106776e73e39d695f3ffc3a9624ece0` |
| `USE_FLASH_LOAN` | Enable/disable atomic flash loans (`true`/`false`) | `true` |
| `SIMULATION_ONLY` | Dry-run `eth_call` without broadcasting txs | `false` |
| `MIN_PROFIT_USD` | Minimum net profit threshold in USD | `10` |

---

## 📄 License
MIT License.
