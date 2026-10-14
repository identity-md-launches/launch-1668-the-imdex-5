// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./Mocks.sol";

/// @dev A fee-on-transfer coin with a settable rate and scope. With `taxAll` false it models
/// SwarmCity: only transfers out of the PoolManager lose `taxBps`. With `taxAll` true every
/// transfer loses it, including the index's settlements into a pool (so a sell leaves the pool
/// short and must fail) and the index's payments to holders. Inherits the plain mock's storage
/// layout and failure modes so it can be etched over a coin that already has balances; the two
/// new fields sit after the inherited ones and start at zero after an etch.
contract TaxERC20 is MockERC20 {
    address public immutable poolManager;
    uint256 public taxBps;
    bool public taxAll;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    function setTax(uint256 bps, bool all) external {
        require(bps <= 10_000, "rate");
        taxBps = bps;
        taxAll = all;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!super.transfer(to, amount)) return false;
        if (taxAll || msg.sender == poolManager) {
            uint256 fee = amount * taxBps / 10_000;
            balanceOf[to] -= fee;
            balanceOf[address(this)] += fee;
        }
        return true;
    }
}
