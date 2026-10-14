// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract Imdex5ShortFillTest is Imdex5Base {
    function setUp() public {
        _deployAll();
        _mintFirst(alice, 1000e18);
    }

    function _costOf(address token, address hook_, uint256 need) internal view returns (uint256) {
        IPoolManager.PoolKey memory key = _key(token, hook_);
        (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(key));
        (uint256 rCoin, uint256 rImd) = key.currency0 == token ? (r0, r1) : (r1, r0);
        return Math.mulDiv(rImd, need, rCoin - need, Math.Rounding.Ceil);
    }

    function test_shortFillMintsTheDeliveredFraction() public {
        uint256 heldBefore = index.held(tokens[3]);
        uint256 need = Math.mulDiv(heldBefore, 100e18, index.totalSupply(), Math.Rounding.Ceil);
        uint256 out = need - need * 2 / 100;
        pm.setShortBy(_key(tokens[3], hooks[3]), need - out);
        vm.prank(bob);
        index.mint(100e18, 2000e18);
        assertEq(index.balanceOf(bob), Math.mulDiv(100e18, out, need));
        assertLt(index.balanceOf(bob), 100e18);
        assertEq(index.held(tokens[3]), heldBefore + out);
        assertEq(MockERC20(tokens[3]).balanceOf(address(index)), heldBefore + out);
        _assertImdAccounting();
    }

    /// @dev Different shortfalls in every list position attack over-issuance and ordering of min().
    function testFuzz_mintUsesTheLeastFilledCoinAndChargesEveryBuy(uint256 shares, uint16[5] memory shortBps) public {
        shares = bound(shares, 1e18, 500e18);
        uint256 supply = index.totalSupply();
        uint256[] memory heldBefore = new uint256[](5);
        uint256[] memory outputs = new uint256[](5);
        uint256 expectedShares = shares;
        uint256 expectedCost;
        for (uint256 i; i < 5; ++i) {
            heldBefore[i] = index.held(tokens[i]);
            uint256 need = Math.mulDiv(heldBefore[i], shares, supply, Math.Rounding.Ceil);
            uint256 shortBy = need * bound(shortBps[i], 0, 9999) / 10_000;
            outputs[i] = need - shortBy;
            expectedShares = Math.min(expectedShares, Math.mulDiv(shares, outputs[i], need));
            expectedCost += _costOf(tokens[i], hooks[i], need);
            pm.setShortBy(_key(tokens[i], hooks[i]), shortBy);
        }
        uint256 feeBefore = index.feeImd();
        uint256 fee = Math.mulDiv(expectedCost, 50, 10_000, Math.Rounding.Ceil);
        vm.expectEmit(true, false, false, true, address(index));
        emit Imdex5.Minted(bob, expectedShares, expectedCost + fee);
        vm.prank(bob);
        index.mint(shares, 2000e18);
        assertGt(expectedShares, 0);
        assertEq(index.balanceOf(bob), expectedShares);
        assertEq(index.totalSupply(), supply + expectedShares);
        assertEq(10_000e18 - imd.balanceOf(bob), expectedCost + fee, "short fills must not discount the buys");
        assertEq(index.feeImd(), feeBefore + fee);
        for (uint256 i; i < 5; ++i) {
            assertEq(index.held(tokens[i]), heldBefore[i] + outputs[i]);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]));
            assertLe(heldBefore[i] * expectedShares, outputs[i] * supply, "minted more than this holding backs");
        }
        _assertImdAccounting();
    }

    /// @dev The idle IMD contribution follows the shares issued: a short fill must not charge
    /// the requested fraction of idle IMD for fewer shares.
    function test_shortFillChargesIdleImdForTheSharesIssuedOnly() public {
        // start again with idle IMD behind the shares: pools that take at most 100 IMD per swap
        _redeemEverything();
        for (uint256 i; i < 5; ++i) {
            pm.setMaxIn(_key(tokens[i], hooks[i]), 100e18);
        }
        _mintFirst(alice, 1000e18);
        for (uint256 i; i < 5; ++i) {
            pm.setMaxIn(_key(tokens[i], hooks[i]), 0);
        }
        uint256 idleBefore = index.idleImd();
        uint256 supply = index.totalSupply();
        assertEq(idleBefore, 495e18);
        assertEq(supply, 995e18);
        uint256 need = Math.mulDiv(index.held(tokens[4]), 100e18, supply, Math.Rounding.Ceil);
        uint256 out = need - need * 2 / 100;
        pm.setShortBy(_key(tokens[4], hooks[4]), need - out);
        vm.prank(bob);
        index.mint(100e18, 2000e18);
        uint256 minted = index.balanceOf(bob);
        assertEq(minted, Math.mulDiv(100e18, out, need));
        assertLe(minted, 98e18);
        uint256 idlePart = index.idleImd() - idleBefore;
        assertEq(idlePart, Math.mulDiv(idleBefore, minted, supply, Math.Rounding.Ceil));
        // the requested fraction would have been ceil(495e18 * 100e18 / 995e18) = 49748743718592964825
        assertLt(idlePart, 49748743718592964825);
        assertLe(idlePart, Math.mulDiv(idleBefore, 98e18, supply, Math.Rounding.Ceil));
        // bob's pro-rata idle claim right after the mint is what bob deposited, to rounding
        uint256 claim = Math.mulDiv(index.idleImd(), minted, index.totalSupply());
        assertLe(idlePart - claim, 2);
        _assertImdAccounting();
    }

    /// @dev A buy that delivers a sliver issues a sliver of shares while the other buys are still
    /// paid in full: the minter is never over-issued and the holders are never diluted, but there
    /// is no minimum-shares floor. The brief keeps it that way; see the README.
    function test_sliverFillIssuesASliverAndChargesEveryBuy() public {
        uint256 supply = index.totalSupply();
        uint256[] memory heldBefore = _holdings();
        uint256 need0 = Math.mulDiv(heldBefore[0], 100e18, supply, Math.Rounding.Ceil);
        uint256 out0 = 1e15;
        pm.setShortBy(_key(tokens[0], hooks[0]), need0 - out0);
        uint256 cost;
        for (uint256 i; i < 5; ++i) {
            cost += _costOf(tokens[i], hooks[i], Math.mulDiv(heldBefore[i], 100e18, supply, Math.Rounding.Ceil));
        }
        uint256 fee = Math.mulDiv(cost, 50, 10_000, Math.Rounding.Ceil);
        vm.prank(bob);
        index.mint(100e18, 2000e18);
        uint256 minted = index.balanceOf(bob);
        assertEq(minted, Math.mulDiv(100e18, out0, need0));
        assertLt(minted, 1e14);
        assertEq(10_000e18 - imd.balanceOf(bob), cost + fee, "every buy made is paid");
        for (uint256 i; i < 5; ++i) {
            uint256 added = index.held(tokens[i]) - heldBefore[i];
            assertLe(heldBefore[i] * minted, added * supply, "mint diluted an existing holding");
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]));
        }
        _assertImdAccounting();
    }

    function _redeemEverything() internal {
        uint256 all = index.balanceOf(alice);
        vm.prank(alice);
        index.redeem(all);
        assertEq(index.totalSupply(), 0);
    }

    function _assertMintRolledBack(uint256[] memory heldBefore, uint256 poolImdBefore) internal view {
        assertEq(index.balanceOf(bob), 0);
        assertEq(index.totalSupply(), 995e18);
        assertEq(index.feeImd(), 5e18);
        assertEq(index.idleImd(), 0);
        assertEq(imd.balanceOf(bob), 10_000e18);
        assertEq(imd.balanceOf(address(pm)), poolImdBefore);
        for (uint256 i; i < 5; ++i) {
            assertEq(index.held(tokens[i]), heldBefore[i]);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), heldBefore[i]);
        }
        _assertImdAccounting();
    }

    function _holdings() internal view returns (uint256[] memory result) {
        result = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            result[i] = index.held(tokens[i]);
        }
    }

    function test_mintRevertsAndRollsBackEarlierBuysWhenACoinDeliversZero() public {
        uint256[] memory heldBefore = _holdings();
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        // At this price and liquidity cap an exact-output swap consumes one IMD wei and
        // delivers zero coin wei. Earlier list coins have already been bought when it fails.
        _setPool(tokens[4], hooks[4], 1e12, 1e24);
        poolImdBefore = imd.balanceOf(address(pm));
        pm.setMaxIn(_key(tokens[4], hooks[4]), 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[4]));
        index.mint(1, 2000e18);
        _assertMintRolledBack(heldBefore, poolImdBefore);
    }

    function test_mintRevertsWhenANonzeroFillRoundsSharesToZero() public {
        uint256[] memory heldBefore = _holdings();
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        uint256 need = Math.mulDiv(heldBefore[4], 1, index.totalSupply(), Math.Rounding.Ceil);
        assertGt(need, 1);
        pm.setShortBy(_key(tokens[4], hooks[4]), 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[4]));
        index.mint(1, 2000e18);
        _assertMintRolledBack(heldBefore, poolImdBefore);
    }

    function test_shortFillStillEnforcesMaxImdInAndRollsBack() public {
        uint256[] memory heldBefore = _holdings();
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        uint256 cost;
        for (uint256 i; i < 5; ++i) {
            uint256 need = Math.mulDiv(heldBefore[i], 100e18, index.totalSupply(), Math.Rounding.Ceil);
            cost += _costOf(tokens[i], hooks[i], need);
            pm.setShortBy(_key(tokens[i], hooks[i]), need / 2);
        }
        uint256 total = cost + Math.mulDiv(cost, 50, 10_000, Math.Rounding.Ceil);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.TooExpensive.selector, total));
        index.mint(100e18, cost);
        _assertMintRolledBack(heldBefore, poolImdBefore);
    }
}
