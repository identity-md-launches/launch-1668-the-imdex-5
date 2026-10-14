// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./Mocks.sol";

/// @dev Models SwarmCity: keeps 2% of transfers out of the PoolManager in the token contract.
/// Transfers from the index, including settlement, redeem and claim, deliver the full amount.
/// Inherits the plain mock's storage layout and failure modes so it can be etched over it.
contract PoolTaxERC20 is MockERC20 {
    address public immutable poolManager;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!super.transfer(to, amount)) return false;
        if (msg.sender == poolManager) {
            uint256 fee = amount * 2 / 100;
            balanceOf[to] -= fee;
            balanceOf[address(this)] += fee;
        }
        return true;
    }
}
