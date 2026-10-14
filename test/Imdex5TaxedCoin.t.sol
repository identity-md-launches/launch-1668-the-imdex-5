// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {PoolTaxERC20} from "./mocks/PoolTaxERC20.sol";

contract Imdex5TaxedCoinTest is Imdex5Base {
    function setUp() public {
        _deployAll();
        assertEq(tokens[4], 0x1ae93A4D9CC0b41C594D00387B6F832a88f729b7);
        vm.etch(tokens[4], address(new PoolTaxERC20(address(pm))).code);
    }

    function _assertAccounting() internal view {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 debt = index.owed(alice, token) + index.owed(bob, token) + index.owed(carol, token);
            assertEq(
                MockERC20(token).balanceOf(address(index)), index.held(token) + debt, "coin balance != held + owed"
            );
        }
        _assertImdAccounting();
    }

    function _assertCleared() internal view {
        _assertAccounting();
        assertEq(index.totalSupply(), 0);
        assertEq(index.idleImd(), 0);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            assertEq(index.held(token), 0);
            assertEq(index.owed(alice, token), 0);
            assertEq(index.owed(bob, token), 0);
            assertEq(index.owed(carol, token), 0);
            assertEq(MockERC20(token).balanceOf(address(index)), 0, "stranded coin");
        }
        assertEq(index.owed(alice, address(imd)) + index.owed(bob, address(imd)) + index.owed(carol, address(imd)), 0);
        // Retained fees remain available for the oracle and caller rewards.
        assertEq(imd.balanceOf(address(index)), index.feeImd());
    }

    function test_firstMintCreditsOnlyWhatArrives() public {
        vm.recordLogs();
        _mintFirst(alice, 1000e18);
        uint256 gross = COIN_RESERVE * 199e18 / (IMD_RESERVE + 199e18);
        uint256 net = gross - gross * 2 / 100;
        assertEq(MockERC20(tokens[4]).balanceOf(address(index)), net);
        assertEq(index.held(tokens[4]), net, "held includes transfer tax");
        assertEq(MockERC20(tokens[4]).balanceOf(tokens[4]), gross - net);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(index)
                    && logs[i].topics[0] == keccak256("Swapped(address,bool,uint256,uint256)")
                    && logs[i].topics[1] == bytes32(uint256(uint160(tokens[4])))
            ) {
                (bool buy, uint256 paid, uint256 out) = abi.decode(logs[i].data, (bool, uint256, uint256));
                assertTrue(buy);
                assertEq(paid, 199e18);
                assertEq(out, net, "Swapped must report the received amount");
                found = true;
            }
        }
        assertTrue(found);
        _assertAccounting();
    }

    /// @dev The audit's last-holder failure, independently of the first-mint accounting assertion.
    function test_lastHolderCanReceiveEveryCoinAfterAnImdExit() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        index.transfer(bob, 200e18);
        vm.prank(alice);
        index.redeemToImd(795e18, 0);
        uint256[] memory remaining = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            remaining[i] = index.held(tokens[i]);
        }
        vm.prank(bob);
        index.redeem(200e18);
        for (uint256 i; i < 5; ++i) {
            assertGt(remaining[i], 0);
            assertEq(MockERC20(tokens[i]).balanceOf(bob), remaining[i], "last holder was not paid");
        }
        _assertCleared();
    }

    /// @dev Each successful mint must be backed by the fraction actually added to EVERY holding.
    function _mintAndCheck(address who, uint256 shares) internal returns (uint256 minted) {
        uint256 supply = index.totalSupply();
        uint256[] memory beforeHeld = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            beforeHeld[i] = index.held(tokens[i]);
        }
        uint256 idleBefore = index.idleImd();
        uint256 feeBefore = index.feeImd();
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        uint256 payerBefore = imd.balanceOf(who);
        uint256 sharesBefore = index.balanceOf(who);
        vm.recordLogs();
        vm.prank(who);
        index.mint(shares, 2000e18);
        minted = index.balanceOf(who) - sharesBefore;
        // the idle contribution follows the shares issued, not the shares asked for
        uint256 idlePart = Math.mulDiv(idleBefore, minted, supply, Math.Rounding.Ceil);
        assertLe(idlePart, Math.mulDiv(idleBefore, shares, supply, Math.Rounding.Ceil));
        uint256 need = Math.mulDiv(beforeHeld[4], shares, supply, Math.Rounding.Ceil);
        uint256 received = need - need * 2 / 100;
        uint256 expected = Math.mulDiv(shares, received, need);
        assertEq(minted, expected);
        assertLt(minted, shares);
        assertEq(index.totalSupply(), supply + minted);
        for (uint256 i; i < 5; ++i) {
            uint256 added = index.held(tokens[i]) - beforeHeld[i];
            uint256 asked = Math.mulDiv(beforeHeld[i], shares, supply, Math.Rounding.Ceil);
            assertEq(added, i == 4 ? received : asked);
            assertLe(beforeHeld[i] * minted, added * supply, "mint diluted an existing holding");
        }
        uint256 cost = imd.balanceOf(address(pm)) - poolImdBefore;
        uint256 fee = Math.mulDiv(cost, 50, 10_000, Math.Rounding.Ceil);
        uint256 paid = payerBefore - imd.balanceOf(who);
        assertGt(cost, 0);
        assertEq(paid, cost + idlePart + fee, "all buys and the issued shares' idle contribution must be charged");
        assertEq(index.feeImd(), feeBefore + fee);
        assertEq(index.idleImd(), idleBefore + idlePart);
        assertLe(idleBefore * minted, idlePart * supply);
        // the minter's pro-rata idle claim right after the mint equals what it deposited, to rounding
        uint256 claim = Math.mulDiv(index.idleImd(), minted, index.totalSupply());
        assertLe(claim, idlePart);
        assertLe(idlePart - claim, 2, "idle charged beyond the issued shares' fraction");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(index) && logs[i].topics[0] == keccak256("Minted(address,uint256,uint256)"))
            {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(who))));
                (uint256 eventShares, uint256 eventPaid) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(eventShares, minted);
                assertEq(eventPaid, paid);
                found = true;
            }
        }
        assertTrue(found, "missing Minted event");
        _assertAccounting();
    }

    function _redeemAllAndCheck(address who) internal {
        uint256 shares = index.balanceOf(who);
        uint256 supply = index.totalSupply();
        uint256 keep = shares == supply ? 10_000 : 9950;
        uint256[] memory expected = new uint256[](5);
        uint256[] memory beforeBalance = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            expected[i] = Math.mulDiv(index.held(tokens[i]), shares * keep, supply * 10_000);
            assertGt(expected[i], 0, "every holder has every coin to receive");
            beforeBalance[i] = MockERC20(tokens[i]).balanceOf(who);
        }
        vm.prank(who);
        index.redeem(shares);
        for (uint256 i; i < 5; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(who) - beforeBalance[i], expected[i]);
            assertEq(index.owed(who, tokens[i]), 0);
        }
        assertEq(index.balanceOf(who), 0);
        _assertAccounting();
    }

    function _lifecycle(uint256 bobShares, uint256 carolShares, uint256 exitShares) internal {
        _assertAccounting();
        // A division remainder also exercises idle IMD through both later mints and every exit.
        _mintFirst(alice, 1000e18 + 7);
        assertGt(index.idleImd(), 0);
        _assertAccounting();
        _mintAndCheck(bob, bobShares);
        _mintAndCheck(carol, carolShares);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        index.redeemToImd(exitShares, 0);
        assertGt(imd.balanceOf(alice), imdBefore);
        _assertAccounting();
        _redeemAllAndCheck(alice);
        _redeemAllAndCheck(bob);
        _redeemAllAndCheck(carol);
        _assertCleared();
    }

    function test_taxedCoinFullLifecycle() public {
        _lifecycle(100e18, 250e18, 400e18);
    }

    function testFuzz_taxedCoinLifecycle(uint256 bobShares, uint256 carolShares, uint256 exitShares) public {
        _lifecycle(bound(bobShares, 1e18, 500e18), bound(carolShares, 1e18, 500e18), bound(exitShares, 1e18, 900e18));
    }

    function test_firstMintMinOutChecksTheNetReceipt() public {
        uint256 gross = COIN_RESERVE * 199e18 / (IMD_RESERVE + 199e18);
        uint256[] memory minOut = _zeros(5);
        minOut[4] = gross;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.TooLittleOut.selector, gross - gross * 2 / 100));
        index.mintFirst(1000e18, minOut);
        assertEq(index.totalSupply(), 0);
        assertEq(imd.balanceOf(alice), 10_000e18);
        _assertAccounting();
    }

    function test_taxedRebalanceBuyCreditsOnlyNewReceipts() public {
        pm.setMaxIn(_key(tokens[4], hooks[4]), 1e18);
        _mintFirst(alice, 1000e18);
        assertGt(index.idleImd(), 0);
        _assertAccounting();
        pm.setMaxIn(_key(tokens[4], hooks[4]), 0);
        _deliverList(_launches(5));
        _assertAccounting();
        uint256 heldBefore = index.held(tokens[4]);
        uint256 taxBefore = MockERC20(tokens[4]).balanceOf(tokens[4]);
        vm.prank(bob);
        index.rebalance();
        assertGt(index.held(tokens[4]), heldBefore, "rebalance did not buy the taxed coin");
        assertGt(MockERC20(tokens[4]).balanceOf(tokens[4]), taxBefore, "rebalance buy did not incur tax");
        _assertAccounting();
        _redeemAllAndCheck(alice);
        _assertCleared();
    }

    function test_outstandingOwedIsNotCountedAsANewReceiptAndRemainsClaimable() public {
        _mintFirst(alice, 1000e18);
        MockERC20(tokens[4]).setFailMode(1);
        vm.prank(alice);
        index.redeem(100e18);
        uint256 debt = index.owed(alice, tokens[4]);
        assertGt(debt, 0);
        _assertAccounting();
        MockERC20(tokens[4]).setFailMode(0);
        _mintAndCheck(bob, 100e18);
        assertEq(index.owed(alice, tokens[4]), debt);
        uint256 balanceBefore = MockERC20(tokens[4]).balanceOf(alice);
        vm.prank(alice);
        index.claim(tokens[4]);
        assertEq(MockERC20(tokens[4]).balanceOf(alice), balanceBefore + debt);
        assertEq(index.owed(alice, tokens[4]), 0);
        _assertAccounting();
        _redeemAllAndCheck(alice);
        _redeemAllAndCheck(bob);
        _assertCleared();
    }
}
