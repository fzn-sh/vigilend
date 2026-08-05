#!/usr/bin/env bash
set -e

RPC_URL="http://127.0.0.1:8545"
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Exact addresses from deployment
POOL="0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0"
ORACLE="0x5fbdb2315678afecb367f032d93f642f64180aa3"
WETH="0xcf7ed3acca5a467e9e704c703e8d87f634fb0fc9"
USDC="0xdc64a140aa3e981100a9beca4e685f962f0cf6c9"
FLASH_RECEIVER="0x5fc8d32690cc91d4c39d9d3abcbd16989f875707"

create_distressed_borrower() {
    BORROWER_KEY=$(cast wallet new | grep "Private key:" | awk '{print $3}')
    BORROWER_ADDR=$(cast wallet address "$BORROWER_KEY")

    # Generate realistic randomized numbers per borrower
    # WETH collateral: 10 to 50 WETH (Value at $3,000 = $30,000 to $150,000 USD)
    WETH_INT=$((RANDOM % 41 + 10))
    WETH_HEX=$(cast --to-uint256 "${WETH_INT}000000000000000000")

    # Borrow LTV: ~65% of initial collateral value ($1,950 per WETH)
    BORROW_INT=$((WETH_INT * 1950))
    BORROW_USDC_RAW="${BORROW_INT}000000"

    echo "1. Resetting WETH Price in MockOracle back to $3,000 initial price..."
    cast send "$ORACLE" "setPrice(address,uint256)" "$WETH" 300000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "2. Minting 10,000,000 USDC liquidity to pool and FlashReceiver..."
    cast send "$USDC" "mint(address,uint256)" "$DEPLOYER_ADDR" 10000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
    cast send "$USDC" "mint(address,uint256)" "$FLASH_RECEIVER" 10000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "3. Deployer approving max USDC allowance to pool and depositing 1,000,000 USDC..."
    cast send "$USDC" "approve(address,uint256)" "$POOL" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
    cast send "$POOL" "deposit(address,uint256,address)" "$USDC" 1000000000000 "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
    cast send "$USDC" "approve(address,uint256)" "$POOL" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "4. Funding fresh borrower $BORROWER_ADDR with 1 ETH gas..."
    cast send "$BORROWER_ADDR" --value 1ether --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "5. Minting $WETH_INT WETH collateral to borrower..."
    cast send "$WETH" "mint(address,uint256)" "$BORROWER_ADDR" "$WETH_HEX" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "6. Borrower approving WETH for VigilendPool..."
    cast send "$WETH" "approve(address,uint256)" "$POOL" "$WETH_HEX" --rpc-url "$RPC_URL" --private-key "$BORROWER_KEY" > /dev/null

    echo "7. Borrower depositing $WETH_INT WETH ($(($WETH_INT * 3000)) USD collateral)..."
    cast send "$POOL" "deposit(address,uint256,address)" "$WETH" "$WETH_HEX" "$BORROWER_ADDR" --rpc-url "$RPC_URL" --private-key "$BORROWER_KEY" > /dev/null

    echo "8. Borrower borrowing $BORROW_INT USDC debt..."
    cast send "$POOL" "borrow(address,uint256,address)" "$USDC" "$BORROW_USDC_RAW" "$BORROWER_ADDR" --rpc-url "$RPC_URL" --private-key "$BORROWER_KEY" > /dev/null

    # Realistic Market Drop (WETH drops from $3000 to $1600 - $1800): HF drops to ~0.7-0.9 (Distressed & Profitable!)
    CRASH_PRICE=$((1600 + RANDOM % 300)) # $1600 - $1900
    CRASH_PRICE_RAW="${CRASH_PRICE}00000000"
    echo "9. CRASHING WETH Price down to \$$CRASH_PRICE in MockOracle (HF ~0.70 - 0.85)..."
    cast send "$ORACLE" "setPrice(address,uint256)" "$WETH" "$CRASH_PRICE_RAW" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "========================================================="
    echo "MARKET DROP SIMULATED FOR BORROWER $BORROWER_ADDR!"
    echo "Collateral: $WETH_INT WETH | Borrowed: \$$BORROW_INT USDC | Crash Price: \$$CRASH_PRICE"
    echo "========================================================="
}

if [ "$1" == "--loop" ]; then
    echo "Starting Continuous Automated Market Simulation (Press Ctrl+C to stop)..."
    while true; do
        create_distressed_borrower
        echo "Sleeping 10s before generating next borrower..."
        sleep 10
    done
else
    create_distressed_borrower
fi
