// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {Imdex5Handler} from "./Imdex5.invariant.t.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {TaxERC20} from "./mocks/TaxERC20.sol";

/// @dev Attacks the corrected accounting where the taxed-coin suite does not: a tax on every
/// list coin at once and at different rates, a tax composed with a partial exact-output fill,
/// a coin that keeps everything (out = 0), a coin that taxes the index's own transfers too (so
/// its sells must fail and fall back to in kind), and a donation that tries to move `held`.
contract Imdex5TaxEverywhereTest is Imdex5Base {
    function setUp() public virtual {
        _deployAll();
        for (uint256 i; i < 5; ++i) {
            vm.etch(tokens[i], address(new TaxERC20(address(pm))).code);
        }
    }

    // ---- helpers ----
    function _setRates(uint16[5] memory rates, bool all) internal {
        for (uint256 i; i < 5; ++i) {
            TaxERC20(tokens[i]).setTax(rates[i], all);
        }
    }

    function _owedTotal(address token) internal view returns (uint256) {
        return index.owed(alice, token) + index.owed(bob, token) + index.owed(carol, token);
    }

    function _assertAccounting() internal view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(
                MockERC20(tokens[i]).balanceOf(address(index)),
                index.held(tokens[i]) + _owedTotal(tokens[i]),
                "coin balance != held + owed"
            );
        }
        _assertImdAccounting();
    }

    function _assertCleared() internal view {
        _assertAccounting();
        assertEq(index.totalSupply(), 0);
        assertEq(index.idleImd(), 0);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(index.held(tokens[i]), 0, "held after the last redeem");
            assertEq(_owedTotal(tokens[i]), 0, "owed after the last redeem");
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 0, "stranded coin");
        }
        assertEq(_owedTotal(address(imd)), 0);
        assertEq(imd.balanceOf(address(index)), index.feeImd());
    }

    function _holdings() internal view returns (uint256[] memory h) {
        h = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            h[i] = index.held(tokens[i]);
        }
    }

    /// @dev Mints and checks the minted shares against the least fraction really added to any
    /// holding, measured from the coin balances rather than the swap's report.
    function _mintAndCheck(address who, uint256 shares) internal returns (uint256 minted) {
        uint256 supply = index.totalSupply();
        uint256[] memory heldBefore = _holdings();
        uint256[] memory balBefore = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            balBefore[i] = MockERC20(tokens[i]).balanceOf(address(index));
        }
        uint256 idleBefore = index.idleImd();
        uint256 payerBefore = imd.balanceOf(who);
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        uint256 sharesBefore = index.balanceOf(who);
        vm.prank(who);
        index.mint(shares, 5000e18);
        minted = index.balanceOf(who) - sharesBefore;
        uint256 expected = shares;
        for (uint256 i; i < 5; ++i) {
            uint256 need = Math.mulDiv(heldBefore[i], shares, supply, Math.Rounding.Ceil);
            uint256 received = MockERC20(tokens[i]).balanceOf(address(index)) - balBefore[i];
            assertEq(index.held(tokens[i]) - heldBefore[i], received, "held credited other than what arrived");
            if (need == 0) continue;
            if (received < need) expected = Math.min(expected, Math.mulDiv(shares, received, need));
            assertLe(heldBefore[i] * minted, received * supply, "minted more than this holding backs");
        }
        assertEq(minted, expected, "minted other than the least delivered fraction");
        assertGt(minted, 0);
        assertEq(index.totalSupply(), supply + minted);
        uint256 cost = imd.balanceOf(address(pm)) - poolImdBefore;
        // the idle contribution follows the shares issued (revision 2), rounded up, never the
        // shares asked for: a short fill must not charge idle IMD the new shares do not own
        uint256 idlePart = Math.mulDiv(idleBefore, minted, supply, Math.Rounding.Ceil);
        uint256 fee = Math.mulDiv(cost, 50, 10_000, Math.Rounding.Ceil);
        assertEq(payerBefore - imd.balanceOf(who), cost + idlePart + fee, "every buy must be paid");
        assertEq(index.idleImd() - idleBefore, idlePart, "idle charged other than the issued fraction");
        assertLe(idleBefore * minted, idlePart * supply, "minted more than the idle contribution backs");
        assertLe(idlePart, Math.mulDiv(idleBefore, shares, supply, Math.Rounding.Ceil), "a short fill overpaid idle");
        _assertAccounting();
    }

    /// @dev Redeems in kind and checks the holder gets the pro-rata share of every coin from
    /// the index's balance (the coin may tax the holder's receipt on its own; the index pays all).
    function _redeemAllAndCheck(address who) internal {
        uint256 shares = index.balanceOf(who);
        uint256 supply = index.totalSupply();
        uint256 keep = shares == supply ? 10_000 : 9950;
        uint256[] memory expected = new uint256[](5);
        uint256[] memory indexBefore = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            expected[i] = Math.mulDiv(index.held(tokens[i]), shares * keep, supply * 10_000);
            indexBefore[i] = MockERC20(tokens[i]).balanceOf(address(index));
        }
        vm.prank(who);
        index.redeem(shares);
        for (uint256 i; i < 5; ++i) {
            assertEq(indexBefore[i] - MockERC20(tokens[i]).balanceOf(address(index)), expected[i], "index paid other");
            assertEq(index.owed(who, tokens[i]), 0, "a payable coin became owed");
        }
        assertEq(index.balanceOf(who), 0);
        _assertAccounting();
    }

    // ---- every coin taxed, at its own rate ----
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_everyCoinTaxedLifecycle(
        uint16[5] memory rates,
        uint256 bobShares,
        uint256 carolShares,
        uint256 exitShares
    ) public {
        for (uint256 i; i < 5; ++i) {
            rates[i] = uint16(bound(rates[i], 0, 5000));
        }
        _setRates(rates, false);
        bobShares = bound(bobShares, 1e18, 500e18);
        carolShares = bound(carolShares, 1e18, 500e18);
        exitShares = bound(exitShares, 1e18, 900e18);

        _mintFirst(alice, 1000e18 + 7);
        // the first mint credits what arrived: the gross buy minus each coin's own tax
        uint256 part = (1000e18 + 7 - Math.mulDiv(1000e18 + 7, 50, 10_000, Math.Rounding.Ceil)) / 5;
        uint256 gross = COIN_RESERVE * part / (IMD_RESERVE + part);
        for (uint256 i; i < 5; ++i) {
            uint256 net = gross - gross * rates[i] / 10_000;
            assertEq(index.held(tokens[i]), net, "first mint credited other than the net receipt");
            assertEq(MockERC20(tokens[i]).balanceOf(tokens[i]), gross - net, "tax not collected");
        }
        _assertAccounting();

        uint256 bobMinted = _mintAndCheck(bob, bobShares);
        uint256 carolMinted = _mintAndCheck(carol, carolShares);
        // the exact expectation from the rates: the worst coin decides
        uint256 worst;
        for (uint256 i; i < 5; ++i) {
            if (rates[i] > worst) worst = rates[i];
        }
        if (worst == 0) {
            assertEq(bobMinted, bobShares);
            assertEq(carolMinted, carolShares);
        } else {
            assertLt(bobMinted, bobShares);
            assertLt(carolMinted, carolShares);
        }

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

    /// @dev Only the most taxed coin decides the minted amount, whichever list position it has.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_theMostTaxedCoinDecidesTheMint(uint8 worstIdx, uint16 worstRate, uint16 otherRate, uint256 shares)
        public
    {
        worstIdx = uint8(bound(worstIdx, 0, 4));
        worstRate = uint16(bound(worstRate, 1, 5000));
        otherRate = uint16(bound(otherRate, 0, worstRate - 1));
        shares = bound(shares, 1e18, 500e18);
        _mintFirst(alice, 1000e18);
        uint16[5] memory rates;
        for (uint256 i; i < 5; ++i) {
            rates[i] = i == worstIdx ? worstRate : otherRate;
        }
        _setRates(rates, false);
        uint256 supply = index.totalSupply();
        uint256 need = Math.mulDiv(index.held(tokens[worstIdx]), shares, supply, Math.Rounding.Ceil);
        uint256 out = need - need * worstRate / 10_000;
        uint256 minted = _mintAndCheck(bob, shares);
        assertEq(minted, Math.mulDiv(shares, out, need), "the worst coin's fraction was not used");
    }

    // ---- a tax composed with a partial fill ----
    function test_taxOnTopOfAPartialFillCreditsTheNetAndMintsThatFraction() public {
        _mintFirst(alice, 1000e18);
        uint16[5] memory rates;
        rates[4] = 200;
        _setRates(rates, false);
        uint256 supply = index.totalSupply();
        uint256 need = Math.mulDiv(index.held(tokens[4]), 100e18, supply, Math.Rounding.Ceil);
        // cap the pool so the exact-output buy fills about half, then the coin keeps 2% of that
        pm.setMaxIn(_key(tokens[4], hooks[4]), 10e18);
        uint256 balBefore = MockERC20(tokens[4]).balanceOf(address(index));
        uint256 poolBefore = MockERC20(tokens[4]).balanceOf(address(pm));
        uint256 minted = _mintAndCheck(bob, 100e18);
        uint256 received = MockERC20(tokens[4]).balanceOf(address(index)) - balBefore;
        uint256 gross = poolBefore - MockERC20(tokens[4]).balanceOf(address(pm));
        assertLt(received, need - need * 200 / 10_000, "the partial fill did not bite");
        assertGt(received, 0);
        assertEq(gross - received, gross * 200 / 10_000, "the coin kept other than its tax");
        assertEq(MockERC20(tokens[4]).balanceOf(tokens[4]), gross - received, "tax not collected");
        assertEq(minted, Math.mulDiv(100e18, received, need));
        pm.setMaxIn(_key(tokens[4], hooks[4]), 0);
        _redeemAllAndCheck(alice);
        _redeemAllAndCheck(bob);
        _assertCleared();
    }

    // ---- a coin that keeps everything ----
    function test_aCoinThatKeepsEverythingFailsTheFirstMintWhole() public {
        uint16[5] memory rates;
        rates[2] = 10_000;
        _setRates(rates, false);
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[2]));
        index.mintFirst(1000e18, _zeros(5));
        assertEq(index.totalSupply(), 0);
        assertEq(imd.balanceOf(alice), 10_000e18, "the first minter was not refunded");
        assertEq(imd.balanceOf(address(pm)), poolImdBefore, "earlier buys were not rolled back");
        for (uint256 i; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 0);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 0);
        }
        _assertAccounting();
    }

    function test_aCoinThatKeepsEverythingFailsALaterMintWholeAndRedeemsStillPay() public {
        // a capped first buy leaves IMD idle for the rebalance below to spend
        pm.setMaxIn(_key(tokens[0], hooks[0]), 50e18);
        _mintFirst(alice, 1000e18);
        pm.setMaxIn(_key(tokens[0], hooks[0]), 0);
        assertGt(index.idleImd(), 0);
        uint256[] memory heldBefore = _holdings();
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        uint16[5] memory rates;
        rates[0] = 10_000;
        _setRates(rates, false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[0]));
        index.mint(100e18, 2000e18);
        assertEq(index.balanceOf(bob), 0);
        assertEq(imd.balanceOf(bob), 10_000e18);
        assertEq(imd.balanceOf(address(pm)), poolImdBefore, "a failed mint moved IMD");
        for (uint256 i; i < 5; ++i) {
            assertEq(index.held(tokens[i]), heldBefore[i]);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), heldBefore[i]);
        }
        _assertAccounting();
        // a rebalance buy of that coin delivers nothing and credits nothing, but spends the IMD:
        // held must stay the real balance even when the swap's report says coins came out
        _deliverList(_launches(5));
        uint256 idleBefore = index.idleImd();
        uint256 poolBefore = MockERC20(tokens[0]).balanceOf(address(pm));
        vm.prank(bob);
        index.rebalance();
        assertLt(MockERC20(tokens[0]).balanceOf(address(pm)), poolBefore, "the pool did not pay the buy out");
        assertEq(index.held(tokens[0]), heldBefore[0], "a buy that delivered nothing was credited");
        assertLt(index.idleImd(), idleBefore, "the rebalance spent nothing");
        _assertAccounting();
        // the holdings are still paid out in kind: the coin taxes only the pool's transfers
        _redeemAllAndCheck(alice);
        _assertCleared();
    }

    function test_aCoinThatKeepsEverythingFailsTheOneWeiMint() public {
        _mintFirst(alice, 1000e18);
        uint16[5] memory rates;
        rates[4] = 9999;
        _setRates(rates, false);
        // need for one share wei is a few coin wei; 99.99% of that rounds the mint to zero shares
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[4]));
        index.mint(1, 2000e18);
        // but a larger mint under the same tax succeeds with the delivered fraction
        uint256 minted = _mintAndCheck(bob, 100e18);
        assertGt(minted, 0);
        assertLt(minted, 100e18 * 2 / 10_000);
    }

    // ---- a coin that taxes every transfer, including the index's own ----
    function _universalCoin() internal {
        uint16[5] memory rates;
        rates[4] = 300;
        _setRates(rates, false);
        TaxERC20(tokens[4]).setTax(300, true);
    }

    function test_aCoinTaxingItsOwnSettlementIsNeverSoldAndIsPaidInKind() public {
        _universalCoin();
        _mintFirst(alice, 1000e18);
        _assertAccounting();
        _mintAndCheck(bob, 100e18);
        // alice exits to IMD: four coins sell, the universal coin's sell leaves the pool short,
        // fails inside swapSelf and is paid in kind under the redeem rule
        uint256 supply = index.totalSupply();
        uint256 heldBefore = index.held(tokens[4]);
        uint256 amount = Math.mulDiv(heldBefore, 300e18, supply);
        uint256 paid = amount * 9950 / 10_000;
        uint256 poolCoinBefore = MockERC20(tokens[4]).balanceOf(address(pm));
        vm.expectEmit(true, false, false, true, address(index));
        emit Imdex5.SwapSkipped(tokens[4], false, amount);
        vm.expectEmit(true, true, false, true, address(index));
        emit Imdex5.Paid(alice, tokens[4], paid);
        vm.prank(alice);
        index.redeemToImd(300e18, 0);
        assertEq(MockERC20(tokens[4]).balanceOf(address(pm)), poolCoinBefore, "the pool received a failed sell");
        assertEq(index.held(tokens[4]), heldBefore - paid, "the unpaid half percent did not stay held");
        assertEq(
            MockERC20(tokens[4]).balanceOf(alice),
            paid - paid * 300 / 10_000,
            "the coin taxes the holder, not the index"
        );
        assertEq(index.owed(alice, tokens[4]), 0);
        _assertAccounting();
        _redeemAllAndCheck(alice);
        _redeemAllAndCheck(bob);
        _assertCleared();
    }

    function test_aCoinTaxingItsOwnSettlementStaysAResidualThroughARebalance() public {
        _universalCoin();
        _mintFirst(alice, 1000e18);
        uint64[] memory list = new uint64[](4);
        for (uint256 i; i < 4; ++i) {
            list[i] = launches[i];
        }
        _deliverList(list);
        uint256 heldBefore = index.held(tokens[4]);
        vm.expectEmit(true, false, false, true, address(index));
        emit Imdex5.SwapSkipped(tokens[4], false, heldBefore);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.listCount(), 4);
        assertEq(index.coins().length, 5, "the unsellable coin was dropped");
        assertEq(index.coins()[4].token, tokens[4]);
        assertEq(index.held(tokens[4]), heldBefore, "held moved without a sale");
        _assertAccounting();
        // later mints skip nothing: the residual is still bought pro rata and credited net
        uint256 need = Math.mulDiv(heldBefore, 100e18, index.totalSupply(), Math.Rounding.Ceil);
        uint256 minted = _mintAndCheck(bob, 100e18);
        assertEq(
            minted, Math.mulDiv(100e18, need - need * 300 / 10_000, need), "the residual's tax did not reduce the mint"
        );
        _redeemAllAndCheck(alice);
        _redeemAllAndCheck(bob);
        _assertCleared();
    }

    // ---- a donation cannot move held or inflate a mint ----
    function test_aDonationNeitherChangesHeldNorInflatesAMintOrARedeem() public {
        _mintFirst(alice, 1000e18);
        uint256[] memory heldBefore = _holdings();
        MockERC20(tokens[1]).mint(address(index), 123e18);
        assertEq(index.held(tokens[1]), heldBefore[1], "a donation changed held");
        uint256 supply = index.totalSupply();
        uint256 need = Math.mulDiv(heldBefore[1], 100e18, supply, Math.Rounding.Ceil);
        uint256 poolBefore = MockERC20(tokens[1]).balanceOf(address(pm));
        vm.prank(bob);
        index.mint(100e18, 2000e18);
        assertEq(index.balanceOf(bob), 100e18);
        assertEq(poolBefore - MockERC20(tokens[1]).balanceOf(address(pm)), need, "the buy was sized by the balance");
        assertEq(index.held(tokens[1]), heldBefore[1] + need);
        uint256 shares = index.balanceOf(alice);
        uint256 expected = Math.mulDiv(index.held(tokens[1]), shares * 9950, index.totalSupply() * 10_000);
        vm.prank(alice);
        index.redeem(shares);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), expected, "a redeem paid from the donation");
        vm.prank(bob);
        index.redeem(100e18);
        assertEq(index.totalSupply(), 0);
        assertEq(index.held(tokens[1]), 0);
        assertEq(MockERC20(tokens[1]).balanceOf(address(index)), 123e18, "only the donation is left");
        for (uint256 i; i < 5; ++i) {
            if (i == 1) continue;
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 0);
        }
    }
}

/// @dev Lets the invariant run change every coin's pool-side tax rate between calls.
contract TaxKnobs {
    address[] public tokens;

    constructor(address[] memory tokens_) {
        tokens = tokens_;
    }

    function setTax(uint256 coin, uint16 bps) external {
        coin = coin % 5;
        TaxERC20(tokens[coin]).setTax(bps % 10_001, false);
    }
}

/// @dev The value invariants over random call sequences, with all five list coins taxed on the
/// pool's transfers at rates the run changes freely, from nothing up to keeping everything. Drives
/// the same handler as the main invariant suite (its per-call checks on the minted fraction and
/// the payment of every buy run here too).
contract Imdex5AllCoinsTaxedInvariantTest is Imdex5Base {
    Imdex5Handler handler;
    uint256 initialPoolImd;

    function setUp() public {
        _deployAll();
        uint16[5] memory rates = [uint16(100), 200, 500, 1000, 2500];
        for (uint256 i; i < 5; ++i) {
            vm.etch(tokens[i], address(new TaxERC20(address(pm))).code);
            TaxERC20(tokens[i]).setTax(rates[i], false);
        }
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        handler = new Imdex5Handler(index, imd, pm, intake, actors, tokens, hooks, launches, KEY_PK);
        initialPoolImd = imd.balanceOf(address(pm));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.mintFirst.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.mint.selector;
        selectors[4] = handler.redeem.selector;
        selectors[5] = handler.redeemToImd.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.transferShares.selector;
        selectors[8] = handler.togglePool.selector;
        selectors[9] = handler.setCoinFailMode.selector;
        selectors[10] = handler.setPoolMaxIn.selector;
        selectors[11] = handler.warp.selector;
        selectors[12] = handler.ask.selector;
        selectors[13] = handler.deliverResult.selector;
        selectors[14] = handler.submit.selector;
        selectors[15] = handler.rebalance.selector;
        selectors[16] = handler.setHookMisbehave.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        TaxKnobs knobs = new TaxKnobs(tokens);
        targetContract(address(knobs));
        bytes4[] memory knobSelectors = new bytes4[](1);
        knobSelectors[0] = knobs.setTax.selector;
        targetSelector(FuzzSelector({addr: address(knobs), selectors: knobSelectors}));
    }

    function _owedTotal(address token) internal view returns (uint256) {
        return index.owed(alice, token) + index.owed(bob, token) + index.owed(carol, token);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_taxed_coinBalancesAreHeldPlusOwed() public view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(
                MockERC20(tokens[i]).balanceOf(address(index)),
                index.held(tokens[i]) + _owedTotal(tokens[i]),
                "coin balance != held + owed"
            );
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_taxed_imdBalanceIsIdlePlusFeePlusOwed() public view {
        assertEq(
            imd.balanceOf(address(index)),
            index.idleImd() + index.feeImd() + _owedTotal(address(imd)),
            "IMD balance != idleImd + feeImd + owed"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_taxed_zeroSupplyMeansNothingHeld() public view {
        if (index.totalSupply() != 0) return;
        assertEq(index.idleImd(), 0, "idle IMD with no shares");
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(index.held(tokens[i]), 0, "coins held with no shares");
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_taxed_actorsNeverExtractMoreImdThanTheyPutIn() public view {
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob) + imd.balanceOf(carol), 30_000e18, "the actors gained IMD");
        assertGe(imd.balanceOf(address(pm)), initialPoolImd, "the pools lost IMD to the index");
        assertEq(handler.ghostFreeMints(), 0, "a mint cost nothing while the index held value");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_taxed_everyHoldingIsListed() public view {
        Imdex5.Coin[] memory coins = index.coins();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (index.held(tokens[i]) == 0) continue;
            bool found;
            for (uint256 j = 0; j < coins.length && !found; ++j) {
                found = coins[j].token == tokens[i];
            }
            assertTrue(found, "a holding fell out of the list");
        }
    }
}
