// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VigilendPool} from "../../src/VigilendPool.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract Handler is Test {
    VigilendPool public pool;
    MockOracle public oracle;
    MockERC20 public weth;
    MockERC20 public usdc;

    address[] public actors;
    address public currentActor;

    mapping(address => uint256) public ghost_userWethShares;
    mapping(address => uint256) public ghost_userUsdcShares;
    mapping(address => uint256) public ghost_userWethDebtShares;
    mapping(address => uint256) public ghost_userUsdcDebtShares;

    uint256 public ghost_sumWethShares;
    uint256 public ghost_sumUsdcShares;
    uint256 public ghost_sumWethDebtShares;
    uint256 public ghost_sumUsdcDebtShares;

    constructor(VigilendPool pool_, MockOracle oracle_, MockERC20 weth_, MockERC20 usdc_) {
        pool = pool_;
        oracle = oracle_;
        weth = weth_;
        usdc = usdc_;

        actors.push(address(0x100));
        actors.push(address(0x200));
        actors.push(address(0x300));

        for (uint256 i = 0; i < actors.length; i++) {
            weth.mint(actors[i], 1_000 ether);
            usdc.mint(actors[i], 1_000_000 * 1e6);

            vm.prank(actors[i]);
            weth.approve(address(pool), type(uint256).max);

            vm.prank(actors[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function _useActor(uint256 actorIndex) internal {
        currentActor = actors[actorIndex % actors.length];
    }

    function depositWeth(uint256 actorSeed, uint256 amount) public {
        _useActor(actorSeed);
        amount = bound(amount, 1 ether, 100 ether);

        vm.prank(currentActor);
        uint256 shares = pool.deposit(address(weth), amount, currentActor);

        ghost_userWethShares[currentActor] += shares;
        ghost_sumWethShares += shares;
    }

    function depositUsdc(uint256 actorSeed, uint256 amount) public {
        _useActor(actorSeed);
        amount = bound(amount, 100 * 1e6, 10_000 * 1e6);

        vm.prank(currentActor);
        uint256 shares = pool.deposit(address(usdc), amount, currentActor);

        ghost_userUsdcShares[currentActor] += shares;
        ghost_sumUsdcShares += shares;
    }

    function withdrawWeth(uint256 actorSeed, uint256 amount) public {
        _useActor(actorSeed);
        uint256 userShares = pool.userCollateralShares(address(weth), currentActor);
        if (userShares == 0) return;

        uint256 maxAmount = pool.totalCollateralAmount(address(weth));
        if (maxAmount == 0) return;

        amount = bound(amount, 1, maxAmount);

        vm.startPrank(currentActor);
        try pool.withdraw(address(weth), amount, currentActor) returns (uint256 burnedShares) {
            ghost_userWethShares[currentActor] -= burnedShares;
            ghost_sumWethShares -= burnedShares;
        } catch {}
        vm.stopPrank();
    }

    function borrowUsdc(uint256 actorSeed, uint256 amount) public {
        _useActor(actorSeed);
        (,, uint256 availableBorrowsUSD,,,) = pool.getUserAccountData(currentActor);
        if (availableBorrowsUSD < 1e18) return;

        // Convert available USD to USDC amount (6 decimals)
        uint256 maxUsdcBorrow = availableBorrowsUSD / 1e12; // 18 decimals -> 6 decimals
        if (maxUsdcBorrow == 0) return;

        amount = bound(amount, 1 * 1e6, maxUsdcBorrow);

        vm.startPrank(currentActor);
        try pool.borrow(address(usdc), amount, currentActor) {
            uint256 debtShares = pool.userDebtShares(address(usdc), currentActor);
            uint256 prevDebtShares = ghost_userUsdcDebtShares[currentActor];
            uint256 addedShares = debtShares - prevDebtShares;

            ghost_userUsdcDebtShares[currentActor] = debtShares;
            ghost_sumUsdcDebtShares += addedShares;
        } catch {}
        vm.stopPrank();
    }

    function warpTime(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 1 minutes, 30 days);
        vm.warp(block.timestamp + timeDelta);
    }
}
