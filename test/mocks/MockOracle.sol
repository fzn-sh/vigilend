// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVigilendOracle} from "../../src/interfaces/IVigilendOracle.sol";

contract MockOracle is IVigilendOracle {
    mapping(address => uint256) private _prices;
    mapping(address => bool) private _isFresh;
    uint8 private constant DECIMALS = 8;

    function setPrice(address asset, uint256 price) external {
        _prices[asset] = price;
        _isFresh[asset] = true;
    }

    function setFreshness(address asset, bool fresh) external {
        _isFresh[asset] = fresh;
    }

    function getPrice(address asset) external view override returns (uint256 price, uint8 decimals) {
        return (_prices[asset], DECIMALS);
    }

    function isFresh(address asset) external view override returns (bool fresh) {
        return _isFresh[asset];
    }
}
