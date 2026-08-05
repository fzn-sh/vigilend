// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VigilendPool} from "../src/VigilendPool.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVigilendPool} from "../src/interfaces/IVigilendPool.sol";
import {InterestRateModel} from "../src/interfaces/InterestRateModel.sol";
import {FlashLiquidationReceiver} from "../src/FlashLiquidationReceiver.sol";

contract VigilendPoolTest is Test {
    VigilendPool public pool;
    MockOracle public oracle;
    MockERC20 public weth;
    MockERC20 public usdc;

    address public constant user1 = address(0x1);
    address public constant user2 = address(0x2);

    function setUp() public {
        oracle = new MockOracle();
        pool = new VigilendPool(address(oracle));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Set Asset Config & Interest Rate Model
        pool.setAssetConfig(address(weth), 7500, 8000, 500, 18);
        pool.setAssetConfig(address(usdc), 8500, 9000, 500, 6);
        InterestRateModel rateModel = new InterestRateModel();
        pool.setInterestRateModel(address(rateModel));
        oracle.setPrice(address(weth), 3000 * 1e8); // $3000
        oracle.setPrice(address(usdc), 1 * 1e8); // $1

        // Mint initial WETH & USDC to users
        weth.mint(user1, 100 ether);
        weth.mint(user2, 100 ether);
        usdc.mint(user1, 100000 * 1e6);
        usdc.mint(user2, 100000 * 1e6);

        vm.prank(user1);
        weth.approve(address(pool), type(uint256).max);

        vm.prank(user2);
        weth.approve(address(pool), type(uint256).max);

        vm.prank(user1);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(user2);
        usdc.approve(address(pool), type(uint256).max);
    }

    function test_BorrowIndexInitialization() public view {
        assertEq(pool.borrowIndex(address(weth)), 1e18);
        assertTrue(pool.lastUpdateTimestamp(address(weth)) > 0);
    }

    function test_DepositSuccess() public {
        vm.prank(user1);
        uint256 shares = pool.deposit(address(weth), 10 ether, user1);

        assertEq(shares, 10 ether);
        assertEq(pool.userCollateralShares(address(weth), user1), 10 ether);
        assertEq(pool.totalCollateralAmount(address(weth)), 10 ether);
        assertEq(weth.balanceOf(address(pool)), 10 ether);
    }

    function test_WithdrawSuccess() public {
        vm.startPrank(user1);
        pool.deposit(address(weth), 10 ether, user1);
        uint256 sharesBurned = pool.withdraw(address(weth), 5 ether, user1);
        vm.stopPrank();

        assertEq(sharesBurned, 5 ether);
        assertEq(pool.userCollateralShares(address(weth), user1), 5 ether);
        assertEq(weth.balanceOf(user1), 95 ether);
    }

    function testFuzz_DepositAndWithdraw(uint96 amount) public {
        vm.assume(amount > 1000 && amount <= 50 ether);

        vm.startPrank(user1);
        pool.deposit(address(weth), amount, user1);
        pool.withdraw(address(weth), amount, user1);
        vm.stopPrank();

        assertEq(pool.userCollateralShares(address(weth), user1), 0);
        assertEq(weth.balanceOf(user1), 100 ether);
    }

    function test_RevertWhen_ZeroDeposit() public {
        vm.prank(user1);
        vm.expectRevert(IVigilendPool.InvalidAmount.selector);
        pool.deposit(address(weth), 0, user1);
    }

    function test_RevertWhen_UnsupportedAsset() public {
        MockERC20 unapprovedToken = new MockERC20("Bad Token", "BAD", 18);
        unapprovedToken.mint(user1, 10 ether);

        vm.startPrank(user1);
        unapprovedToken.approve(address(pool), type(uint256).max);
        vm.expectRevert(IVigilendPool.AssetNotSupported.selector);
        pool.deposit(address(unapprovedToken), 1 ether, user1);
        vm.stopPrank();
    }

    function test_WithdrawTooMuch() public {
        vm.prank(user1);
        uint256 shares = pool.deposit(address(weth), 10 ether, user1);

        assertEq(shares, 10 ether);
        assertEq(pool.userCollateralShares(address(weth), user1), 10 ether);
        assertEq(pool.totalCollateralAmount(address(weth)), 10 ether);
        assertEq(weth.balanceOf(address(pool)), 10 ether);

        vm.startPrank(user1);
        vm.expectRevert("INSUFFICIENT_BALANCE");
        pool.withdraw(address(weth), 15 ether, user1);
        vm.stopPrank();
    }

    function test_DepositOnBehalfOf() public {
        vm.prank(user1);
        uint256 shares = pool.deposit(address(weth), 5 ether, user2);

        assertEq(shares, 5 ether);
        assertEq(weth.balanceOf(address(pool)), 5 ether);
        assertEq(pool.userCollateralShares(address(weth), user2), 5 ether);
        assertEq(pool.totalCollateralAmount(address(weth)), 5 ether);

        // check collateral shares user1 (shouldn't have increased)
        assertEq(pool.userCollateralShares(address(weth), user1), 0);

        // check total ether balance user1 and user2
        assertEq(weth.balanceOf(user1), 95 ether);
        assertEq(weth.balanceOf(user2), 100 ether);
    }

    function test_BorrowSuccess() public {
        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1);

        vm.prank(user1);
        pool.borrow(address(weth), 5 ether, user1);

        assertEq(weth.balanceOf(user1), 95 ether); // 100 - 10 deposited + 5 borrowed
        assertEq(pool.userDebtShares(address(weth), user1), 5 ether);

        (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 availableBorrowsUSD,,, uint256 healthFactor) =
            pool.getUserAccountData(user1);

        assertEq(totalCollateralUSD, 30000 * 1e18); // 10 WETH * $3000
        assertEq(totalDebtUSD, 15000 * 1e18); // 5 WETH * $3000
        assertEq(availableBorrowsUSD, 7500 * 1e18); // Max $22500 - $15000 = $7500
        assertTrue(healthFactor >= 1e18);
    }

    function test_RepaySuccess() public {
        vm.startPrank(user1);
        pool.deposit(address(weth), 10 ether, user1);
        pool.borrow(address(weth), 5 ether, user1);

        uint256 repaid = pool.repay(address(weth), 2 ether, user1);
        vm.stopPrank();

        assertEq(repaid, 2 ether);
        assertEq(pool.userDebtShares(address(weth), user1), 3 ether);
        assertEq(weth.balanceOf(user1), 93 ether); // 95 - 2 repaid
    }

    function test_RevertWhen_BorrowTooMuch() public {
        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1); // Collateral = $30,000, Max Borrow LTV (75%) = $22,500 (7.5 WETH)

        vm.prank(user1);
        vm.expectRevert(IVigilendPool.InsufficientCollateral.selector);
        pool.borrow(address(weth), 8 ether, user1); // 8 WETH = $24,000 > $22,500 -> Reverts!
    }

    function test_LiquidateSuccess() public {
        // user2 supplies USDC to liquidity pool so user1 can borrow USDC
        vm.prank(user2);
        pool.deposit(address(usdc), 50000 * 1e6, user2);

        // user1 deposits 10 WETH ($30,000 USD collateral)
        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1);

        // user1 borrows 15,000 USDC ($15,000 USD debt)
        vm.prank(user1);
        pool.borrow(address(usdc), 15000 * 1e6, user1);

        // WETH price crashes from $3000 to $1800
        // Collateral = 10 * $1800 = $18,000 USD
        // Max Liquidation Threshold Value = $18,000 * 80% = $14,400 USD
        // Debt = $15,000 USD -> HF = $14,400 / $15,000 = 0.96 < 1.0 (Liquidatable!)
        oracle.setPrice(address(weth), 1800 * 1e8);

        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user1);
        assertTrue(healthFactor < 1e18);

        // Liquidator (user2) liquidates user1's position for 5,000 USDC
        vm.prank(user2);
        uint256 seizedCollateral = pool.liquidate(address(weth), address(usdc), user1, 5000 * 1e6);

        // 5000 USDC + 5% bonus = $5250 USD collateral seized
        assertTrue(seizedCollateral > 0);
        assertTrue(pool.userCollateralShares(address(weth), user2) > 0);
    }

    function test_RevertWhen_LiquidateHealthyUser() public {
        vm.prank(user2);
        pool.deposit(address(usdc), 50000 * 1e6, user2);

        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1);

        vm.prank(user1);
        pool.borrow(address(usdc), 5000 * 1e6, user1);

        // User1 HF is healthy (> 1.0)
        vm.prank(user2);
        vm.expectRevert(IVigilendPool.HealthFactorOk.selector);
        pool.liquidate(address(weth), address(usdc), user1, 2000 * 1e6);
    }

    function test_FlashLoanLiquidationReceiver() public {
        // Setup USDC liquidity in pool
        vm.prank(user2);
        pool.deposit(address(usdc), 50000 * 1e6, user2);

        // User1 deposits WETH and borrows USDC
        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1);
        vm.prank(user1);
        pool.borrow(address(usdc), 15000 * 1e6, user1);

        // Crash WETH price ($3000 -> $1500)
        oracle.setPrice(address(weth), 1500 * 1e8);

        // Deploy FlashLiquidationReceiver by User2 (Liquidator with 0 USDC balance)
        vm.startPrank(user2);
        FlashLiquidationReceiver receiver = new FlashLiquidationReceiver(address(pool));

        // Prepare flash loan params (collateralAsset, borrower)
        bytes memory params = abi.encode(address(weth), user1);
        uint256 debtToCover = 5000 * 1e6;

        // User2 funds receiver contract with 0.09% flash loan fee + principal buffer for mock test
        usdc.transfer(address(receiver), 5005 * 1e6);

        // Execute capital-free flash loan liquidation!
        pool.flashLoan(address(receiver), address(usdc), debtToCover, params);
        vm.stopPrank();

        // Verify liquidator (user2) received seized WETH collateral!
        assertTrue(weth.balanceOf(user2) > 0);
    }

    function test_ReserveAccrualAndWithdrawal() public {
        // Configure 10% reserve factor for USDC
        pool.setReserveFactor(address(usdc), 1000);

        // User2 deposits USDC and User1 deposits WETH + borrows USDC
        vm.prank(user2);
        pool.deposit(address(usdc), 50000 * 1e6, user2);

        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1);

        vm.prank(user1);
        pool.borrow(address(usdc), 10000 * 1e6, user1);

        // Warp 180 days to elapse time and accrue interest
        vm.warp(block.timestamp + 180 days);
        pool.accrueInterest(address(usdc));

        uint256 reserve = pool.totalReserveAmount(address(usdc));
        assertTrue(reserve > 0);

        address treasury = address(0x99);
        pool.withdrawReserve(address(usdc), reserve, treasury);

        assertEq(usdc.balanceOf(treasury), reserve);
        assertEq(pool.totalReserveAmount(address(usdc)), 0);
    }

    function test_SocializeBadDebtSuccess() public {
        // User2 supplies USDC
        vm.prank(user2);
        pool.deposit(address(usdc), 50000 * 1e6, user2);

        // User1 deposits 10 WETH ($30,000) and borrows 15,000 USDC ($15,000)
        vm.prank(user1);
        pool.deposit(address(weth), 10 ether, user1);

        vm.prank(user1);
        pool.borrow(address(usdc), 15000 * 1e6, user1);

        // WETH price crashes to $1000 -> Liquidate undercollateralized position
        oracle.setPrice(address(weth), 1000 * 1e8);

        vm.startPrank(user2);
        pool.liquidate(address(weth), address(usdc), user1, 7500 * 1e6);
        pool.liquidate(address(weth), address(usdc), user1, 3750 * 1e6);
        vm.stopPrank();

        // WETH price drops further to $100 -> User1 has 0 collateral left, but remaining USDC debt
        oracle.setPrice(address(weth), 100 * 1e8);

        assertEq(pool.userCollateralShares(address(weth), user1), 0);
        assertTrue(pool.userDebtShares(address(usdc), user1) > 0);

        // Socialize remaining bad debt
        uint256 socialized = pool.socializeBadDebt(address(weth), address(usdc), user1);

        assertTrue(socialized > 0);
        assertEq(pool.userDebtShares(address(usdc), user1), 0);
    }
}
