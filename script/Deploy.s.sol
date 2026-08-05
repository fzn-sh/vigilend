// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VigilendPool} from "../src/VigilendPool.sol";
import {MockOracle} from "../test/mocks/MockOracle.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {InterestRateModel} from "../src/interfaces/InterestRateModel.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        MockOracle oracle = new MockOracle();
        InterestRateModel interestRateModel = new InterestRateModel();
        VigilendPool pool = new VigilendPool(address(oracle));

        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // Configure Markets
        pool.setAssetConfig(address(weth), 7500, 8000, 500, 18);
        pool.setAssetConfig(address(usdc), 8500, 9000, 500, 6);
        pool.setInterestRateModel(address(interestRateModel));

        // Set Initial Prices ($3000 WETH, $1 USDC)
        oracle.setPrice(address(weth), 3000 * 1e8);
        oracle.setPrice(address(usdc), 1 * 1e8);

        // Mint Initial Liquidity to Deployer and Test User
        address testUser = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8); // Anvil Account #1
        weth.mint(deployer, 1000 ether);
        usdc.mint(deployer, 1_000_000 * 1e6);
        weth.mint(testUser, 100 ether);
        usdc.mint(testUser, 100_000 * 1e6);

        vm.stopBroadcast();

        console.log("================ DEPLOYMENT SUCCESSFUL ================");
        console.log("Deployer Address:     ", deployer);
        console.log("MockOracle Address:   ", address(oracle));
        console.log("InterestRateModel:    ", address(interestRateModel));
        console.log("VigilendPool Address: ", address(pool));
        console.log("WETH Address:         ", address(weth));
        console.log("USDC Address:         ", address(usdc));
        console.log("=======================================================");
    }
}
