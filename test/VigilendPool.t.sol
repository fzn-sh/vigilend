// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VigilendPool} from "../src/VigilendPool.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVigilendPool} from "../src/interfaces/IVigilendPool.sol";

contract VigilendPoolTest is Test {
    VigilendPool public pool;
    MockOracle public oracle;
    MockERC20 public weth;

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        oracle = new MockOracle();
        pool = new VigilendPool(address(oracle));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Set Asset Config
        pool.setAssetConfig(address(weth), 7500, 8000, 500, 18);
        oracle.setPrice(address(weth), 3000 * 1e8); // $3000

        // Mint initial WETH to users
        weth.mint(user1, 100 ether);
        weth.mint(user2, 100 ether);

        vm.prank(user1);
        weth.approve(address(pool), type(uint256).max);

        vm.prank(user2);
        weth.approve(address(pool), type(uint256).max);
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
}
