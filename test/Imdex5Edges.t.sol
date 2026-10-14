// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Imdex5} from "../src/Imdex5.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {GasBurnerERC20, ReentrantERC20, RevertingIntake} from "./mocks/AttackMocks.sol";

/// @title Edges, failure paths and attacks the behaviour suite does not reach
contract Imdex5EdgesTest is Imdex5Base {
    function setUp() public {
        _deployAll();
    }

    // ---- fee threshold and ask liveness ----
    function test_askThresholdIsExactlyThreeQuartersOfAnImd() public {
        vm.prank(alice);
        index.fund(0.75e18 - 1);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 0, "asked under the threshold");
        assertEq(index.lastAsk(), 0, "a returned ask must not start the interval");
        assertEq(index.openSince(), 0);
        vm.prank(alice);
        index.fund(1);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 1);
        assertEq(index.feeImd(), 0);
        assertEq(imd.balanceOf(bob), 10_000e18 + 0.25e18);
        assertEq(imd.balanceOf(address(intake)), 0.5e18);
        _assertImdAccounting();
    }

    function test_askRevertsWholeWhenTheIntakeRefuses() public {
        vm.etch(address(intake), address(new RevertingIntake()).code);
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        vm.expectRevert("intake closed");
        index.ask();
        assertEq(index.feeImd(), 1e18, "fees must not leave for a request that was not made");
        assertEq(index.openSince(), 0);
        assertEq(index.lastAsk(), 0);
        assertEq(imd.balanceOf(bob), 10_000e18);
    }

    function test_closingARequestDoesNotResetTheInterval() public {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        vm.warp(block.timestamp + 2 days);
        vm.prank(carol);
        index.closeRequest();
        vm.prank(bob);
        vm.expectRevert(Imdex5.AskTooSoon.selector);
        index.ask();
        vm.warp(START + 7 days);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
    }

    function test_closeRequestNeedsAnOpenOne() public {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert(Imdex5.NoRequest.selector);
        index.closeRequest();
    }

    // ---- callback forgeries ----
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_onOracleResultFromAStrangerChangesNothing(address caller, bytes32 id, uint16 agreed) public {
        vm.assume(caller != address(intake));
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        a.agreed = agreed;
        vm.prank(caller);
        index.onOracleResult(id, a, "");
        vm.prank(caller);
        index.onOracleFailure(id, 1, bytes32("x"), 0, 0, "");
        assertEq(index.answerHash(), bytes32(0));
        assertGt(index.openSince(), 0);
        assertEq(index.feeImd(), 0.25e18);
        _assertImdAccounting();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_onOracleResultForAnotherRequestIsIgnored(bytes32 id, uint16 agreed) public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        vm.assume(id != intake.lastRequestId());
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        a.agreed = agreed;
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), bytes32(0));
        assertGt(index.openSince(), 0);
    }

    function test_onOracleResultAfterCloseIsIgnored() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        vm.warp(block.timestamp + 2 days);
        vm.prank(carol);
        index.closeRequest();
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), bytes32(0), "a closed request must not accept a late answer");
        vm.prank(address(intake));
        index.onOracleFailure(id, 2, bytes32("disagreed"), 2, 5, "");
        assertEq(index.openSince(), 0);
    }

    function test_onOracleResultWithFiveEntriesFitsTheStipend() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        uint256 before = imd.balanceOf(address(index));
        vm.prank(address(intake));
        index.onOracleResult{gas: 200_000}(id, a, "");
        assertEq(index.answerHash(), keccak256(a.answer));
        assertEq(imd.balanceOf(address(index)), before, "the callback must move nothing");
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 0);
        }
    }

    function test_aLaterAskReplacesAnUnsubmittedAnswer() public {
        vm.prank(alice);
        index.fund(5e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory first = _attestation(_launches(3));
        _deliver(first);
        bytes memory firstSig = _sign(first);
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        index.ask();
        // the week-old answer is stale the moment the new request opens, not only once the new
        // answer arrives: submitting it now would rebalance twice in one cycle
        assertGt(index.openSince(), 0);
        assertLt(first.expiresAt, block.timestamp);
        assertEq(index.answerHash(), bytes32(0), "a new ask must drop the unsubmitted answer");
        vm.prank(carol);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(first, firstSig);
        assertEq(index.nextList().length, 0);
        OracleAttestation.Attestation memory second = _attestation(_launches(4));
        _deliver(second);
        bytes memory secondSig = _sign(second);
        vm.prank(carol);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(first, firstSig);
        vm.prank(carol);
        index.submit(second, secondSig);
        assertEq(index.nextList().length, 4);
    }

    /// @dev A new ask that fails or times out leaves no answer at all: the old one is gone and
    /// the loop waits for the next interval, as it does after any failed round.
    function test_anUnsubmittedAnswerDoesNotSurviveAFailedLaterAsk() public {
        vm.prank(alice);
        index.fund(5e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory first = _attestation(_launches(3));
        _deliver(first);
        bytes memory firstSig = _sign(first);
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleFailure(id, 2, bytes32("disagreed"), 2, 5, "");
        assertEq(index.openSince(), 0);
        assertEq(index.answerHash(), bytes32(0));
        vm.prank(carol);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(first, firstSig);
        // an ask that returns without opening a request (fees short) changes nothing
        vm.prank(bob);
        vm.expectRevert(Imdex5.AskTooSoon.selector);
        index.ask();
    }

    // ---- attestation forgeries ----
    function test_submitRejectsAnAttestationSignedForAnotherConsumer() public {
        Imdex5 other = new Imdex5();
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _deliver(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, other.attestationDigest(a));
        vm.prank(bob);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, abi.encodePacked(r, s, v));
        assertEq(index.nextList().length, 0);
    }

    function test_submitRejectsAnAttestationSignedForAnotherChain() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _deliver(a);
        bytes memory sig = _sign(a);
        vm.chainId(1);
        vm.prank(bob);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, sig);
        vm.chainId(31_337);
        vm.prank(bob);
        index.submit(a, sig);
        assertEq(index.nextList().length, 3);
    }

    function test_submitRejectsATamperedAnswerEvenWithAValidSignatureElsewhere() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory delivered = _attestation(_launches(3));
        _deliver(delivered);
        // the signer honestly signed a different answer (another consumer's or an older one)
        OracleAttestation.Attestation memory signed = _attestation(_launches(5));
        bytes memory sig = _sign(signed);
        // present the signed one with the delivered answer spliced in
        signed.answer = delivered.answer;
        vm.prank(bob);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(signed, sig);
    }

    function test_submitRejectsMalformedAnswerBytes() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(1));
        a.answer = hex"deadbeef";
        _deliver(a);
        assertEq(index.answerHash(), keccak256(a.answer), "the callback stores any hash");
        bytes memory sig = _sign(a);
        vm.prank(bob);
        vm.expectRevert();
        index.submit(a, sig);
        assertEq(index.nextList().length, 0);
        // the round is not lost: anyone may ask again after the interval
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
    }

    // ---- rewards only when fees can pay ----
    function test_submitAndRebalancePayNoRewardWithoutFees() public {
        _mintFirst(alice, 100e18); // feeImd = 0.5
        vm.prank(alice);
        index.fund(0.25e18); // 0.75 exactly
        vm.prank(bob);
        index.ask();
        assertEq(index.feeImd(), 0);
        OracleAttestation.Attestation memory a = _attestation(_launches(4));
        _deliver(a);
        uint256 carolBefore = imd.balanceOf(carol);
        bytes memory sig = _sign(a);
        vm.prank(carol);
        index.submit(a, sig);
        assertEq(index.feeImd(), 0);
        assertEq(imd.balanceOf(carol), carolBefore, "no reward without fees");
        vm.prank(carol);
        index.rebalance();
        assertEq(index.feeImd(), 0);
        assertEq(imd.balanceOf(carol), carolBefore);
        _assertImdAccounting();
    }

    function test_rewardsNeverDipIntoIdleImd() public {
        _mintFirst(alice, 100e18 + 7); // leaves 1 wei of idle and 0.5 IMD + 1 wei of fees
        assertEq(index.idleImd(), 1);
        uint256 topUp = 0.75e18 - index.feeImd();
        vm.prank(alice);
        index.fund(topUp);
        vm.prank(bob);
        index.ask();
        assertEq(index.feeImd(), 0);
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        _deliver(a);
        bytes memory sig = _sign(a);
        vm.prank(carol);
        index.submit(a, sig);
        vm.prank(carol);
        index.rebalance();
        assertEq(index.idleImd() + index.feeImd(), imd.balanceOf(address(index)));
    }

    // ---- redeem cannot be blocked ----
    function test_redeemToATokenWithoutCodeBecomesOwedAndClaimableLater() public {
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[0]);
        bytes memory code = tokens[0].code;
        vm.etch(tokens[0], "");
        vm.prank(alice);
        index.redeem(995e18);
        assertEq(index.owed(alice, tokens[0]), h, "a call to no code must be recorded, not treated as paid");
        assertEq(index.held(tokens[0]), 0);
        vm.etch(tokens[0], code);
        vm.prank(alice);
        index.claim(tokens[0]);
        assertEq(MockERC20(tokens[0]).balanceOf(alice), h);
        assertEq(index.owed(alice, tokens[0]), 0);
    }

    function test_redeemIdleImdThatCannotBeSentIsOwed() public {
        _mintFirst(alice, 1000e18 + 7);
        assertEq(index.idleImd(), 1);
        imd.setFailMode(2);
        uint256 all = index.balanceOf(alice);
        vm.prank(alice);
        index.redeem(all);
        assertEq(index.owed(alice, address(imd)), 1);
        assertEq(index.idleImd(), 0);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + 1);
        imd.setFailMode(0);
        vm.prank(alice);
        index.claim(address(imd));
        assertEq(index.owed(alice, address(imd)), 0);
        _assertImdAccounting();
    }

    function test_aReenteringCoinCannotReenterAndIsNotPaidTwice() public {
        // replace coin 0 with a coin that re-enters the index during transfer
        ReentrantERC20 evil = ReentrantERC20(tokens[0]);
        vm.etch(tokens[0], address(new ReentrantERC20()).code);
        evil.mint(address(pm), COIN_RESERVE);
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[0]);
        uint256 paidPart = h * 199e18 * 9950 / (995e18 * 10_000);

        // (a) re-enter redeem during payment: blocked, the payment still completes once
        evil.arm(address(index), abi.encodeCall(Imdex5.redeem, (1)), false);
        vm.prank(alice);
        index.redeem(199e18);
        assertGt(evil.attempts(), 0);
        assertFalse(evil.reentered(), "redeem re-entered");
        assertEq(evil.balanceOf(alice), paidPart);
        assertEq(index.balanceOf(alice), 995e18 - 199e18, "the re-entered redeem must not have burned");

        // (b) a coin that reverts when its re-entry is blocked becomes owed
        evil.arm(address(index), abi.encodeCall(Imdex5.claim, (tokens[0])), true);
        vm.prank(alice);
        index.redeem(199e18);
        uint256 owedNow = index.owed(alice, tokens[0]);
        assertGt(owedNow, 0);
        assertEq(evil.balanceOf(alice), paidPart, "nothing paid when the transfer reverted");

        // (c) claim: the coin re-enters claim during the payout; the guard blocks it and the
        // debt is paid exactly once
        evil.arm(address(index), abi.encodeCall(Imdex5.claim, (tokens[0])), false);
        vm.prank(alice);
        index.claim(tokens[0]);
        assertFalse(evil.reentered(), "claim re-entered");
        assertEq(evil.balanceOf(alice), paidPart + owedNow);
        assertEq(index.owed(alice, tokens[0]), 0);
        vm.prank(alice);
        vm.expectRevert(Imdex5.NothingOwed.selector);
        index.claim(tokens[0]);
        assertEq(evil.balanceOf(address(index)), index.held(tokens[0]));
    }

    function test_aReenteringCoinCannotReenterMintOrRebalanceFromRedeem() public {
        ReentrantERC20 evil = ReentrantERC20(tokens[2]);
        vm.etch(tokens[2], address(new ReentrantERC20()).code);
        evil.mint(address(pm), COIN_RESERVE);
        _mintFirst(alice, 1000e18);
        _deliverList(_launches(4));
        evil.arm(address(index), abi.encodeCall(Imdex5.rebalance, ()), false);
        vm.prank(alice);
        index.redeem(100e18);
        assertFalse(evil.reentered());
        assertEq(index.nextList().length, 4, "rebalance ran inside redeem");
        evil.arm(address(index), abi.encodeCall(Imdex5.mint, (1, 1e18)), false);
        vm.prank(alice);
        index.redeem(100e18);
        assertFalse(evil.reentered());
        _assertImdAccounting();
    }

    function test_oneGasBurningCoinDoesNotBlockRedeemGivenGas() public {
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[1]);
        vm.etch(tokens[1], address(new GasBurnerERC20()).code);
        vm.prank(alice);
        index.redeem{gas: 30_000_000}(995e18);
        assertEq(index.totalSupply(), 0);
        assertEq(index.owed(alice, tokens[1]), h, "the burner must be recorded as owed");
        for (uint256 i = 0; i < 5; ++i) {
            if (i == 1) continue;
            assertEq(MockERC20(tokens[i]).balanceOf(alice), h);
        }
    }

    // ---- redeem arithmetic ----
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_redeemNeverPaysAboveProRata(uint256 first, uint256 shares) public {
        first = bound(first, 1e18, 5000e18);
        _mintFirst(alice, first);
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1, supply);
        uint256[] memory before = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            before[i] = index.held(tokens[i]);
        }
        vm.prank(alice);
        index.redeem(shares);
        for (uint256 i = 0; i < 5; ++i) {
            uint256 paid = MockERC20(tokens[i]).balanceOf(alice);
            uint256 proRata = before[i] * shares / supply;
            assertLe(paid, proRata, "paid above pro rata");
            if (shares < supply) assertLe(paid, proRata * 9950 / 10_000 + 1, "paid above 99.5%");
            assertEq(index.held(tokens[i]), before[i] - paid);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]));
        }
        assertEq(index.totalSupply(), supply - shares);
        _assertImdAccounting();
    }

    /// @dev Splitting a redeem recoups part of the first step's 0.5% retention, as any remaining
    /// holder would, but can never reach the plain pro-rata amount.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_splittingARedeemStaysUnderProRata(uint256 a, uint256 b) public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        index.transfer(bob, 1e18); // somebody else stays in, so the fee has someone to go to
        uint256 supply = index.totalSupply();
        uint256 h = index.held(tokens[0]);
        a = bound(a, 1, supply - 1e18 - 1);
        b = bound(b, 1, supply - 1e18 - a);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        index.redeem(a + b);
        uint256 whole = MockERC20(tokens[0]).balanceOf(alice);
        vm.revertToState(snap);
        vm.prank(alice);
        index.redeem(a);
        vm.prank(alice);
        index.redeem(b);
        uint256 split = MockERC20(tokens[0]).balanceOf(alice);
        assertLe(split, h * (a + b) / supply, "splitting a redeem pays above pro rata");
        assertGe(split + 2, whole, "splitting a redeem should not pay less than one redeem");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_mintFirstMintsExactlyTheRest(uint256 imdIn) public {
        imdIn = bound(imdIn, 6, 5000e18); // under 6 wei the equal part is 0 and the mint reverts
        _mintFirst(alice, imdIn);
        uint256 fee = (imdIn * 50 + 9999) / 10_000;
        uint256 rest = imdIn - fee;
        assertEq(index.feeImd(), fee);
        assertEq(index.totalSupply(), rest);
        assertEq(index.balanceOf(alice), rest);
        assertEq(index.idleImd(), rest - (rest / 5) * 5);
        assertLt(index.idleImd(), 5);
        _assertImdAccounting();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_mintBuysExactlyTheRoundedUpShare(uint256 shares) public {
        _mintFirst(alice, 1000e18);
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1, 3 * supply);
        uint256[] memory before = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            before[i] = index.held(tokens[i]);
        }
        vm.prank(bob);
        index.mint(shares, 10_000e18);
        for (uint256 i = 0; i < 5; ++i) {
            uint256 need = (before[i] * shares + supply - 1) / supply;
            assertEq(index.held(tokens[i]), before[i] + need);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]));
        }
        assertEq(index.balanceOf(bob), shares);
        uint256 paid = 10_000e18 - imd.balanceOf(bob);
        // coins were bought at or above the price the first mint paid, so a share costs at least 1 IMD
        assertGe(paid, shares);
        _assertImdAccounting();
    }

    function test_mintCannotBeFreeWhenTheIndexHoldsValue() public {
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        vm.expectRevert();
        index.mint(1, 0);
        assertEq(index.balanceOf(bob), 0);
    }

    // ---- redeem fee stays with holders, not feeImd ----
    function test_redeemHalfPercentStaysWithRemainingHolders() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        index.transfer(bob, 495e18);
        uint256 h = index.held(tokens[0]);
        uint256 feeBefore = index.feeImd();
        vm.prank(alice);
        index.redeem(500e18);
        uint256 paid = MockERC20(tokens[0]).balanceOf(alice);
        assertEq(paid, h * 500e18 * 9950 / (995e18 * 10_000));
        assertEq(index.feeImd(), feeBefore, "redeem must not touch feeImd");
        // bob, the last holder, now takes everything that is left, including alice's 0.5%
        vm.prank(bob);
        index.redeem(495e18);
        assertEq(MockERC20(tokens[0]).balanceOf(bob), h - paid);
        assertGt(MockERC20(tokens[0]).balanceOf(bob), h * 495e18 / 995e18);
        assertEq(index.held(tokens[0]), 0);
        assertEq(index.totalSupply(), 0);
    }

    // ---- rebalance limits ----
    function test_rebalanceSellMovesAPoolAtMostTwoPercent() public {
        _mintFirst(alice, 1000e18);
        uint256 before = _priceOf(tokens[4], hooks[4]);
        _deliverList(_launches(4));
        vm.prank(bob);
        index.rebalance();
        uint256 after_ = _priceOf(tokens[4], hooks[4]);
        assertLt(after_, before, "the leaver was not sold");
        assertGe(after_, before * 9795 / 10_000, "the sale moved the price past 2%");
        assertLe(after_, before * 9805 / 10_000, "the sale stopped short of its limit");
        assertGt(index.held(tokens[4]), 0, "a limited sale leaves a residual");
    }

    function test_rebalanceBuyMovesAPoolAtMostTwoPercent() public {
        // deep pools for the leavers so they sell whole and leave plenty of idle IMD
        _setPool(tokens[3], hooks[3], COIN_RESERVE * 1000, IMD_RESERVE * 1000);
        _setPool(tokens[4], hooks[4], COIN_RESERVE * 1000, IMD_RESERVE * 1000);
        _mintFirst(alice, 1000e18);
        uint64[] memory list = new uint64[](4);
        list[0] = 1282;
        list[1] = 1283;
        list[2] = 737;
        list[3] = 2000;
        uint256 before = _priceOf(NEW_TOKEN, HOOK_G);
        _deliverList(list);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.held(tokens[3]), 0, "a deep pool should sell the whole leaver");
        uint256 after_ = _priceOf(NEW_TOKEN, HOOK_G);
        assertGt(after_, before);
        assertLe(after_, before * 10_205 / 10_000, "the buy moved the price past 2%");
        assertGt(index.idleImd(), 0, "what the limit did not spend stays idle");
        _assertImdAccounting();
    }

    function test_rebalanceBuyStopsAtAQuarterWeight() public {
        // a very deep pool for the new coin: the 2% limit never binds, the weight cap must
        _setPool(NEW_TOKEN, HOOK_G, COIN_RESERVE * 100_000, IMD_RESERVE * 100_000);
        _setPool(tokens[3], hooks[3], COIN_RESERVE * 100_000, IMD_RESERVE * 100_000);
        _setPool(tokens[4], hooks[4], COIN_RESERVE * 100_000, IMD_RESERVE * 100_000);
        _mintFirst(alice, 1000e18);
        uint64[] memory list = new uint64[](4);
        list[0] = 1282;
        list[1] = 1283;
        list[2] = 737;
        list[3] = 2000;
        _deliverList(list);
        uint256[] memory heldBefore = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            heldBefore[i] = index.held(tokens[i]);
        }
        vm.prank(bob);
        index.rebalance();
        // the two leavers (about 40% of value) became idle; each list coin may take at most a
        // quarter of total value, so the three at ~20% top up a little and the new one is capped
        uint256 total = index.idleImd();
        Imdex5.Coin[] memory coins = index.coins();
        uint256[] memory values = new uint256[](coins.length);
        for (uint256 i = 0; i < coins.length; ++i) {
            values[i] = index.held(coins[i].token) * _priceOf(coins[i].token, coins[i].hook) / 1e18;
            total += values[i];
        }
        for (uint256 i = 0; i < coins.length; ++i) {
            assertLe(values[i], total / 4 + total / 100, "a buy went past a quarter of total value");
        }
        assertGt(index.held(NEW_TOKEN), 0);
        assertGt(index.idleImd(), 0, "idle IMD the cap kept from being spent must remain");
        for (uint256 i = 0; i < 3; ++i) {
            assertGe(index.held(tokens[i]), heldBefore[i]);
        }
        _assertImdAccounting();
    }

    function test_rebalanceDoesNotTrimWithFewerThanFourCoins() public {
        _mintFirst(alice, 1000e18);
        // coin 0 triples in price: now about 43% of value
        pm.setPool(_key(tokens[0], hooks[0]), 0, 0);
        _setPool(tokens[0], hooks[0], COIN_RESERVE, 3 * IMD_RESERVE);
        _deliverList(_launches(3));
        uint256 heldA = index.held(tokens[0]);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.held(tokens[0]), heldA, "a three-coin list must not trim");
        assertEq(index.listCount(), 3);
    }

    function test_rebalanceTrimsToAQuarterNotBelow() public {
        _mintFirst(alice, 1000e18);
        // coin 0 at 4x the price: about 50% of value, far over a quarter
        pm.setPool(_key(tokens[0], hooks[0]), 0, 0);
        _setPool(tokens[0], hooks[0], COIN_RESERVE * 100, 4 * IMD_RESERVE * 100);
        _deliverList(_launches(5));
        vm.prank(bob);
        index.rebalance();
        uint256 total = index.idleImd();
        uint256 v0;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 v = index.held(tokens[i]) * _priceOf(tokens[i], hooks[i]) / 1e18;
            total += v;
            if (i == 0) v0 = v;
        }
        // trimmed down towards a quarter (the 2% limit may stop it short of exactly a quarter)
        assertLt(v0, total * 50 / 100);
        assertGe(v0, total * 24 / 100, "trimmed below a quarter");
    }

    function test_residualsAreRedeemedAndBlockMintWhileTheirPoolIsDead() public {
        _mintFirst(alice, 1000e18);
        _deliverList(_launches(4));
        pm.setDead(_key(tokens[4], hooks[4]), true);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.coins().length, 5);
        assertEq(index.listCount(), 4);
        // accepted by the brief: a dead pool blocks mint
        vm.prank(bob);
        vm.expectRevert();
        index.mint(1e18, 100e18);
        // never redeem: alice gets her share of the residual in kind
        uint256 heldE = index.held(tokens[4]);
        vm.prank(alice);
        index.redeem(199e18);
        assertEq(MockERC20(tokens[4]).balanceOf(alice), heldE * 199e18 * 9950 / (995e18 * 10_000));
        // redeemToImd pays the dead residual in kind and the rest in IMD
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        index.redeemToImd(199e18, 0);
        assertGt(imd.balanceOf(alice), imdBefore);
        assertGt(MockERC20(tokens[4]).balanceOf(alice), heldE * 199e18 * 9950 / (995e18 * 10_000));
        // once the pool is back, mint works again and buys the residual proportionally
        pm.setDead(_key(tokens[4], hooks[4]), false);
        uint256 heldE2 = index.held(tokens[4]);
        vm.prank(bob);
        index.mint(1e18, 100e18);
        assertGt(index.held(tokens[4]), heldE2);
        _assertImdAccounting();
    }

    // ---- the share is a plain ERC-20 ----
    function test_sharesTransferLikeAnyErc20AndMoveNoHoldings() public {
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[0]);
        vm.prank(alice);
        assertTrue(index.transfer(bob, 100e18));
        vm.prank(alice);
        index.approve(carol, 50e18);
        vm.prank(carol);
        assertTrue(index.transferFrom(alice, carol, 50e18));
        assertEq(index.balanceOf(alice), 845e18);
        assertEq(index.balanceOf(bob), 100e18);
        assertEq(index.balanceOf(carol), 50e18);
        assertEq(index.allowance(alice, carol), 0);
        assertEq(index.totalSupply(), 995e18);
        assertEq(index.held(tokens[0]), h);
        vm.prank(alice);
        vm.expectRevert();
        index.transfer(address(0), 1);
        // a transferee can redeem what they received
        vm.prank(bob);
        index.redeem(100e18);
        assertGt(MockERC20(tokens[0]).balanceOf(bob), 0);
    }
}
