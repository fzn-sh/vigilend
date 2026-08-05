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

create_distressed_borrower() {
    BORROWER_KEY=$(cast wallet new | grep "Private key:" | awk '{print $3}')
    BORROWER_ADDR=$(cast wallet address "$BORROWER_KEY")

    echo "1. Resetting WETH Price in MockOracle back to $3,000 initial price..."
    cast send "$ORACLE" "setPrice(address,uint256)" "$WETH" 300000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "2. Minting 1,000,000 fresh USDC to Deployer for liquidator balance..."
    cast send "$USDC" "mint(address,uint256)" "$DEPLOYER_ADDR" 1000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "3. Deployer approving max USDC allowance to pool and depositing 100,000 USDC..."
    cast send "$USDC" "approve(address,uint256)" "$POOL" 1000000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
    cast send "$POOL" "deposit(address,uint256,address)" "$USDC" 100000000000 "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "4. Funding fresh borrower $BORROWER_ADDR with 1 ETH gas fees..."
    cast send "$BORROWER_ADDR" --value 1ether --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "5. Minting 10 WETH collateral to fresh borrower $BORROWER_ADDR..."
    cast send "$WETH" "mint(address,uint256)" "$BORROWER_ADDR" 10000000000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "6. Borrower approving WETH for VigilendPool..."
    cast send "$WETH" "approve(address,uint256)" "$POOL" 100000000000000000000 --rpc-url "$RPC_URL" --private-key "$BORROWER_KEY" > /dev/null

    echo "7. Borrower depositing 10 WETH ($30,000 USD collateral)..."
    cast send "$POOL" "deposit(address,uint256,address)" "$WETH" 10000000000000000000 "$BORROWER_ADDR" --rpc-url "$RPC_URL" --private-key "$BORROWER_KEY" > /dev/null

    echo "8. Borrower borrowing 10,000 USDC ($10,000 USD debt)..."
    cast send "$POOL" "borrow(address,uint256,address)" "$USDC" 10000000000 "$BORROWER_ADDR" --rpc-url "$RPC_URL" --private-key "$BORROWER_KEY" > /dev/null

    echo "9. CRASHING WETH Price from $3000 down to $100 in MockOracle..."
    cast send "$ORACLE" "setPrice(address,uint256)" "$WETH" 10000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

    echo "========================================================="
    echo "CRASH SIMULATED FOR BORROWER $BORROWER_ADDR!"
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
