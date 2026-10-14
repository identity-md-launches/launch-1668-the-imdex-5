// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockERC20, MockIntake, MockPoolManager, MockRegistry, MockSigner, ReentrantHook} from "./mocks/Mocks.sol";

contract Imdex5Test is Test {
    using stdStorage for StdStorage;

    uint256 constant KEY_PK = 0xA11CE;
    address constant HOOK_G = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address constant HOOK_M = 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc;
    address constant NEW_TOKEN = 0x1111111111111111111111111111111111111111;
    uint256 constant COIN_RESERVE = 1_000_000e18;
    uint256 constant IMD_RESERVE = 10_000e18;

    Imdex5 index;
    MockERC20 imd;
    MockPoolManager pm;
    MockRegistry regA;
    MockRegistry regB;
    MockIntake intake;
    ReentrantHook hook;
    ReentrantHook hookM;
    address signerKey;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address[] tokens;
    address[] hooks;
    uint256 asks;

    function setUp() public {
        vm.warp(1_800_000_000);
        index = new Imdex5();
        imd = MockERC20(index.IMD());
        vm.etch(address(imd), address(new MockERC20()).code);
        pm = MockPoolManager(index.POOL_MANAGER());
        vm.etch(address(pm), address(new MockPoolManager()).code);
        regA = MockRegistry(address(index.REGISTRY_A()));
        vm.etch(address(regA), address(new MockRegistry()).code);
        regB = MockRegistry(address(index.REGISTRY_B()));
        vm.etch(address(regB), address(new MockRegistry()).code);
        intake = MockIntake(index.INTAKE());
        vm.etch(address(intake), address(new MockIntake()).code);
        signerKey = vm.addr(KEY_PK);
        vm.etch(index.ORACLE_SIGNER(), address(new MockSigner(signerKey)).code);
        hook = ReentrantHook(HOOK_G);
        vm.etch(HOOK_G, address(new ReentrantHook()).code);
        hookM = ReentrantHook(HOOK_M);
        vm.etch(HOOK_M, address(new ReentrantHook()).code);

        Imdex5.Coin[] memory coins = index.coins();
        for (uint256 i = 0; i < coins.length; ++i) {
            vm.etch(coins[i].token, address(new MockERC20()).code);
            tokens.push(coins[i].token);
            hooks.push(coins[i].hook);
            _setPool(coins[i].token, coins[i].hook, COIN_RESERVE, IMD_RESERVE);
            MockRegistry reg = i == 1 ? regA : regB;
            reg.record(coins[i].launch, coins[i].token, coins[i].hook);
        }
        vm.etch(NEW_TOKEN, address(new MockERC20()).code);
        _setPool(NEW_TOKEN, HOOK_G, COIN_RESERVE, IMD_RESERVE);
        regA.record(2000, NEW_TOKEN, HOOK_G);

        imd.mint(alice, 10_000e18);
        imd.mint(bob, 10_000e18);
        vm.prank(alice);
        imd.approve(address(index), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(index), type(uint256).max);
    }

    // ---- helpers ----
    function _key(address token, address hook_) internal view returns (IPoolManager.PoolKey memory) {
        (address c0, address c1) = address(imd) < token ? (address(imd), token) : (token, address(imd));
        return IPoolManager.PoolKey(c0, c1, index.POOL_FEE(), index.TICK_SPACING(), hook_);
    }

    function _setPool(address token, address hook_, uint256 coinReserve, uint256 imdReserve) internal {
        IPoolManager.PoolKey memory key = _key(token, hook_);
        (uint256 r0, uint256 r1) = key.currency0 == token ? (coinReserve, imdReserve) : (imdReserve, coinReserve);
        pm.setPool(key, r0, r1);
        MockERC20(token).mint(address(pm), coinReserve);
        imd.mint(address(pm), imdReserve);
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](5);
    }

    function _mintFirst(address who, uint256 amount) internal {
        vm.prank(who);
        index.mintFirst(amount, _zeros());
    }

    function _attestation(uint64[] memory launches) internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](launches.length);
        for (uint256 i = 0; i < launches.length; ++i) {
            ids[i] = bytes32(uint256(launches[i]));
        }
        a = OracleAttestation.Attestation({
            requestId: keccak256("oracle uuid"),
            chainId: 1,
            questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: keccak256("panel"),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1_800_000_000,
            expiresAt: 1_800_086_400
        });
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, index.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _launches(uint256 n) internal view returns (uint64[] memory l) {
        Imdex5.Coin[] memory coins = index.coins();
        l = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) {
            l[i] = coins[i].launch;
        }
    }

    /// @dev Funds fees, asks, delivers the answer through the intake and submits it.
    function _deliverList(uint64[] memory launches) internal {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(launches);
        bytes32 id = intake.lastRequestId();
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        vm.prank(bob);
        index.submit(a, sig);
    }

    function _sumHeldValue() internal view returns (uint256 total) {
        Imdex5.Coin[] memory coins = index.coins();
        for (uint256 i = 0; i < coins.length; ++i) {
            total += index.held(coins[i].token);
        }
    }

    // ---- deployment ----
    function test_deployment() public view {
        assertEq(index.name(), "The Imdex 5");
        assertEq(index.symbol(), "IMDEX5");
        assertEq(index.decimals(), 18);
        assertEq(index.totalSupply(), 0);
        assertEq(index.listCount(), 5);
        Imdex5.Coin[] memory coins = index.coins();
        assertEq(coins.length, 5);
        assertEq(coins[0].token, 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921);
        assertEq(coins[0].launch, 1282);
        assertEq(coins[1].hook, 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc);
        assertEq(coins[4].launch, 1175);
        assertEq(index.oracleSigner(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertLe(address(index).code.length, 24_576);
    }

    function test_bodyIsTheJsonTheBriefDescribes() public {
        string memory body = string(index.body());
        assertTrue(vm.contains(body, '{"v":1,"question":"'));
        assertTrue(vm.contains(body, '"chainId":1,"window":{"hours":24},"answerType":"bytes32[]","evidence":"panel"'));
        assertTrue(vm.contains(body, '"panelSize":5,"quorum":4,"validForSeconds":86400,"head":5'));
        assertTrue(
            vm.contains(
                body,
                string.concat(
                    '"consumer":{"chainId":1,"verifyingContract":"', vm.toLowercase(vm.toString(address(index))), '"}}'
                )
            )
        );
        assertTrue(vm.contains(body, "100 IMD or more"));
        assertTrue(vm.contains(body, "USDC, USDT and imdUSD"));
    }

    // ---- fund ----
    function test_fundAddsToFeeImd() public {
        vm.prank(alice);
        index.fund(3e18);
        assertEq(index.feeImd(), 3e18);
        assertEq(imd.balanceOf(address(index)), 3e18);
        vm.prank(alice);
        vm.expectRevert(Imdex5.ZeroAmount.selector);
        index.fund(0);
    }

    // ---- mintFirst ----
    function test_mintFirstBuysEqualPartsAndTakesFee() public {
        _mintFirst(alice, 1000e18);
        assertEq(index.feeImd(), 5e18);
        assertEq(index.totalSupply(), 995e18);
        assertEq(index.balanceOf(alice), 995e18);
        assertEq(index.idleImd(), 0);
        uint256 expectedOut = COIN_RESERVE * 199e18 / (IMD_RESERVE + 199e18);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.held(tokens[i]), expectedOut);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), expectedOut);
        }
        assertEq(imd.balanceOf(address(index)), 5e18);
        assertEq(imd.balanceOf(alice), 9000e18);
    }

    function test_mintFirstRevertsOnMinOut() public {
        uint256[] memory minOut = _zeros();
        minOut[2] = type(uint256).max;
        vm.prank(alice);
        vm.expectRevert();
        index.mintFirst(1000e18, minOut);
    }

    function test_mintFirstRevertsWhenABuyFails() public {
        pm.setDead(_key(tokens[3], hooks[3]), true);
        vm.prank(alice);
        vm.expectRevert();
        index.mintFirst(1000e18, _zeros());
    }

    function test_mintFirstRevertsWhenABuyReturnsNothing() public {
        // a buy the pool fee swallows whole (one wei in, nothing out) is a failed buy, not a
        // free share: the dust first mint reverts and the index stays open for an honest one
        pm.setShortBy(_key(tokens[4], hooks[4]), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[4]));
        index.mintFirst(6, _zeros());
        assertEq(index.totalSupply(), 0);
        assertEq(imd.balanceOf(bob), 10_000e18);
        vm.prank(bob);
        vm.expectRevert(Imdex5.FirstMintOnly.selector);
        index.mint(1_000_000e18, 0);
        pm.setShortBy(_key(tokens[4], hooks[4]), 0);
        _mintFirst(alice, 1000e18);
        assertEq(index.totalSupply(), 995e18);
    }

    function test_mintNeverIssuesSharesForNothing() public {
        // a supply with nothing behind it (unreachable through the contract, forced here) cannot
        // be minted against: a mint that would cost nothing reverts
        stdstore.target(address(index)).sig("totalSupply()").checked_write(uint256(5));
        assertEq(index.totalSupply(), 5);
        vm.prank(bob);
        vm.expectRevert(Imdex5.NothingToPay.selector);
        index.mint(1_000_000e18, 0);
        assertEq(index.balanceOf(bob), 0);
    }

    function test_mintFirstKeepsWhatAPoolCouldNotTakeAsIdle() public {
        // one pool's liquidity ends after 10 IMD: the unspent 189 IMD of its part is the holders'
        pm.setMaxIn(_key(tokens[2], hooks[2]), 10e18);
        _mintFirst(alice, 1000e18);
        assertEq(index.feeImd(), 5e18);
        assertEq(index.totalSupply(), 995e18);
        assertEq(index.idleImd(), 189e18);
        assertEq(index.held(tokens[2]), COIN_RESERVE * 10e18 / (IMD_RESERVE + 10e18));
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
        // and it is paid out on redeem
        vm.prank(alice);
        index.redeem(995e18);
        assertEq(imd.balanceOf(alice), 9000e18 + 189e18);
        assertEq(index.idleImd(), 0);
    }

    function test_mintFirstRequiresZeroSupplyAndRightLength() public {
        vm.prank(alice);
        vm.expectRevert(Imdex5.BadLength.selector);
        index.mintFirst(1000e18, new uint256[](4));
        vm.prank(alice);
        vm.expectRevert(Imdex5.ZeroAmount.selector);
        index.mintFirst(0, _zeros());
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        vm.expectRevert(Imdex5.NotFirstMint.selector);
        index.mintFirst(1000e18, _zeros());
    }

    // ---- mint ----
    function test_mintBuysProportionallyAndRefunds() public {
        _mintFirst(alice, 1000e18);
        uint256 heldBefore = index.held(tokens[0]);
        uint256 feeBefore = index.feeImd();
        vm.prank(bob);
        index.mint(995e18, 3000e18);
        assertEq(index.balanceOf(bob), 995e18);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 2 * heldBefore);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 2 * heldBefore);
        }
        uint256 paid = 10_000e18 - imd.balanceOf(bob);
        uint256 cost = imd.balanceOf(address(pm)) - 6 * IMD_RESERVE - 5 * 199e18;
        uint256 fee = (cost * 50 + 9999) / 10_000;
        assertEq(index.feeImd(), feeBefore + fee);
        assertEq(paid, cost + fee);
        assertGt(cost, 995e18);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
    }

    function test_mintRevertsOverMaxImdIn() public {
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        vm.expectRevert();
        index.mint(995e18, 1000e18);
        assertEq(imd.balanceOf(bob), 10_000e18);
    }

    function test_mintRevertsWhenABuyFailsButScalesANonzeroShortFill() public {
        _mintFirst(alice, 1000e18);
        pm.setDead(_key(tokens[1], hooks[1]), true);
        vm.prank(bob);
        vm.expectRevert();
        index.mint(100e18, 3000e18);
        pm.setDead(_key(tokens[1], hooks[1]), false);
        pm.setShortBy(_key(tokens[1], hooks[1]), 1);
        uint256 heldBefore = index.held(tokens[1]);
        uint256 supply = index.totalSupply();
        uint256 need = (heldBefore * 100e18 + supply - 1) / supply;
        vm.prank(bob);
        index.mint(100e18, 3000e18);
        // The corrected launch issues only the delivered fraction, even for a one-wei shortfall.
        uint256 minted = 100e18 * (need - 1) / need;
        assertEq(index.balanceOf(bob), minted);
        assertLt(minted, 100e18);
        assertEq(index.totalSupply(), supply + minted);
        assertEq(index.held(tokens[1]), heldBefore + need - 1);
        for (uint256 i; i < 5; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]));
        }
    }

    function test_mintRoundsAgainstTheMinter() public {
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        index.mint(1, 1e18);
        assertEq(index.balanceOf(bob), 1);
        assertGt(10_000e18 - imd.balanceOf(bob), 0);
        for (uint256 i = 0; i < 5; ++i) {
            assertGt(index.held(tokens[i]) - COIN_RESERVE * 199e18 / (IMD_RESERVE + 199e18), 0);
        }
    }

    function test_mintRequiresSupply() public {
        vm.prank(bob);
        vm.expectRevert(Imdex5.FirstMintOnly.selector);
        index.mint(1e18, 1e18);
    }

    // ---- redeem ----
    function test_redeemPaysInKindLessHalfPercent() public {
        _mintFirst(alice, 1000e18);
        uint256 heldBefore = index.held(tokens[0]);
        vm.prank(alice);
        index.redeem(199e18);
        uint256 expected = heldBefore * 199e18 * 9950 / (995e18 * 10_000);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(alice), expected);
            assertEq(index.held(tokens[i]), heldBefore - expected);
        }
        assertEq(index.totalSupply(), 796e18);
        assertEq(index.feeImd(), 5e18);
    }

    function test_redeemLastSharesPaysEverything() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        index.redeem(995e18);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 0);
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 0);
        }
        assertEq(index.totalSupply(), 0);
        assertEq(index.feeImd(), 5e18);
        _mintFirst(bob, 10e18);
        assertEq(index.balanceOf(bob), 9.95e18);
    }

    function test_redeemCannotBeBlockedByACoin() public {
        _mintFirst(alice, 1000e18);
        pm.setDead(_key(tokens[0], hooks[0]), true);
        MockERC20(tokens[1]).setFailMode(1);
        MockERC20(tokens[2]).setFailMode(2);
        uint256 heldBefore = index.held(tokens[1]);
        vm.prank(alice);
        index.redeem(995e18);
        assertEq(MockERC20(tokens[0]).balanceOf(alice), heldBefore);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), 0);
        assertEq(index.owed(alice, tokens[1]), heldBefore);
        assertEq(index.owed(alice, tokens[2]), heldBefore);
        assertEq(index.held(tokens[1]), 0);
        MockERC20(tokens[1]).setFailMode(0);
        MockERC20(tokens[2]).setFailMode(0);
        vm.prank(alice);
        index.claim(tokens[1]);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), heldBefore);
        assertEq(index.owed(alice, tokens[1]), 0);
        vm.prank(alice);
        vm.expectRevert(Imdex5.NothingOwed.selector);
        index.claim(tokens[1]);
        vm.prank(bob);
        vm.expectRevert(Imdex5.NothingOwed.selector);
        index.claim(tokens[2]);
    }

    function test_redeemSurvivesCoinsThatBurnAllGas() public {
        _mintFirst(alice, 1000e18);
        MockERC20(tokens[2]).setFailMode(3);
        MockERC20(tokens[3]).setFailMode(3);
        uint256 heldBefore = index.held(tokens[2]);
        uint256 expected = heldBefore * 500e18 * 9950 / (995e18 * 10_000);
        vm.prank(alice);
        index.redeem{gas: 3_000_000}(500e18);
        assertEq(index.owed(alice, tokens[2]), expected);
        assertEq(index.owed(alice, tokens[3]), expected);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), expected);
        assertEq(index.held(tokens[2]), heldBefore - expected);
        // the leftover 0.5% stays, so the second redeem still works with every coin hostile
        for (uint256 i = 0; i < 5; ++i) {
            MockERC20(tokens[i]).setFailMode(3);
        }
        vm.prank(alice);
        index.redeem{gas: 3_000_000}(495e18);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 0);
            assertGt(index.owed(alice, tokens[i]), 0);
            MockERC20(tokens[i]).setFailMode(0);
            vm.prank(alice);
            index.claim(tokens[i]);
            assertEq(MockERC20(tokens[i]).balanceOf(alice), heldBefore);
        }
    }

    function test_redeemRejectsZeroAndTooMany() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(Imdex5.ZeroAmount.selector);
        index.redeem(0);
        vm.prank(bob);
        vm.expectRevert();
        index.redeem(1);
    }

    // ---- redeemToImd ----
    function test_redeemToImdSellsAndKeepsFee() public {
        _mintFirst(alice, 1000e18);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        index.redeemToImd(995e18, 900e18);
        uint256 got = imd.balanceOf(alice) - before;
        assertGt(got, 900e18);
        assertLt(got, 995e18);
        uint256 proceeds = 6 * IMD_RESERVE + 5 * 199e18 - imd.balanceOf(address(pm));
        uint256 fee = (proceeds * 50 + 9999) / 10_000;
        assertEq(got, proceeds - fee);
        assertEq(index.feeImd(), 5e18 + fee);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 0);
        }
        assertEq(imd.balanceOf(address(index)), index.feeImd());
    }

    function test_redeemToImdRevertsBelowMinOut() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert();
        index.redeemToImd(995e18, 995e18);
        assertEq(index.balanceOf(alice), 995e18);
    }

    function test_redeemToImdPaysInKindWhenASaleFails() public {
        _mintFirst(alice, 1000e18);
        pm.setDead(_key(tokens[2], hooks[2]), true);
        uint256 h = index.held(tokens[2]);
        vm.prank(alice);
        index.redeemToImd(199e18, 0);
        // the in-kind payment follows the redeem rule: 99.50%, the rest stays with the holders
        uint256 part = h * 199e18 / 995e18;
        uint256 paid = part * 9950 / 10_000;
        assertEq(MockERC20(tokens[2]).balanceOf(alice), paid);
        assertEq(index.held(tokens[2]), h - paid);
        assertGt(imd.balanceOf(alice), 9000e18);
        // the same redeem pays the same amount of that coin
        vm.prank(alice);
        index.redeemToImd(199e18, 0);
        uint256 h2 = h - paid;
        uint256 paid2 = (h2 * 199e18 / 796e18) * 9950 / 10_000;
        assertEq(MockERC20(tokens[2]).balanceOf(alice), paid + paid2);
        // the last redeemer takes all of it
        vm.prank(alice);
        index.redeemToImd(597e18, 0);
        assertEq(index.held(tokens[2]), 0);
        assertEq(MockERC20(tokens[2]).balanceOf(alice), h);
        assertEq(index.totalSupply(), 0);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
    }

    function test_redeemToImdPaysAShortFillInKindLessHalfPercent() public {
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[1]);
        uint256 part = h * 199e18 / 995e18;
        pm.setMaxIn(_key(tokens[1], hooks[1]), part / 2);
        vm.prank(alice);
        index.redeemToImd(199e18, 0);
        uint256 unsold = part - part / 2;
        uint256 paid = unsold * 9950 / 10_000;
        assertEq(MockERC20(tokens[1]).balanceOf(alice), paid);
        assertEq(index.held(tokens[1]), h - part / 2 - paid);
        assertEq(MockERC20(tokens[1]).balanceOf(address(index)), index.held(tokens[1]));
    }

    function test_redeemToImdSurvivesAHookThatBurnsGas() public {
        _mintFirst(alice, 1000e18);
        hookM.setMisbehave(hookM.MISBEHAVE_BURN(), address(index));
        uint256 h = index.held(tokens[1]);
        vm.expectEmit(true, false, false, true, address(index));
        emit Imdex5.SwapSkipped(tokens[1], false, h * 199e18 / 995e18);
        vm.prank(alice);
        index.redeemToImd{gas: 4_000_000}(199e18, 0);
        uint256 paid = (h * 199e18 / 995e18) * 9950 / 10_000;
        assertEq(MockERC20(tokens[1]).balanceOf(alice), paid);
        assertGt(imd.balanceOf(alice), 9000e18);
    }

    // ---- oracle ----
    function test_askReturnsWithoutFees() public {
        vm.prank(alice);
        index.fund(0.5e18);
        vm.prank(bob);
        index.ask();
        assertEq(index.openSince(), 0);
        assertEq(intake.count(), 0);
        assertEq(index.feeImd(), 0.5e18);
    }

    function test_askPaysIntakeAndCaller() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 1);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastAmount(), 0.5e18);
        assertEq(imd.balanceOf(address(intake)), 0.5e18);
        assertEq(imd.balanceOf(bob), 10_000.25e18);
        assertEq(index.feeImd(), 0.25e18);
        assertEq(index.openRequest(), intake.lastRequestId());
        assertEq(index.openSince(), block.timestamp);
        assertEq(index.lastAsk(), block.timestamp);
        (address target, bytes4 selector) = intake.lastCallback();
        assertEq(target, address(index));
        assertEq(selector, index.onOracleResult.selector);
        assertEq(intake.lastOnFailure(), index.onOracleFailure.selector);
        assertEq(keccak256(intake.lastBody()), keccak256(index.body()));
        vm.prank(bob);
        vm.expectRevert(Imdex5.RequestOpen.selector);
        index.ask();
    }

    function test_askSevenDayInterval() public {
        vm.prank(alice);
        index.fund(5e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleFailure(id, 2, bytes32("disagreed"), 2, 5, "");
        assertEq(index.openSince(), 0);
        vm.prank(bob);
        vm.expectRevert(Imdex5.AskTooSoon.selector);
        index.ask();
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
    }

    function test_onOracleResultStoresOnlyTheOpenRequestFromTheIntake() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        bytes32 id = intake.lastRequestId();
        // forged caller
        vm.prank(bob);
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), bytes32(0));
        // wrong request
        vm.prank(address(intake));
        index.onOracleResult(keccak256("other"), a, "");
        assertEq(index.answerHash(), bytes32(0));
        // too little agreement
        a.agreed = 3;
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), bytes32(0));
        assertGt(index.openSince(), 0);
        // the real thing, under the stipend
        a.agreed = 4;
        vm.prank(address(intake));
        index.onOracleResult{gas: 200_000}(id, a, "");
        assertEq(index.answerHash(), keccak256(a.answer));
        assertEq(index.openSince(), 0);
        assertEq(imd.balanceOf(address(index)), 0.25e18);
        // a second delivery changes nothing
        a.answer = abi.encode(new bytes32[](0));
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), keccak256(_attestation(_launches(3)).answer));
    }

    function test_onOracleFailureOnlyFromIntake() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        vm.prank(bob);
        index.onOracleFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        assertGt(index.openSince(), 0);
        vm.prank(address(intake));
        index.onOracleFailure(keccak256("other"), 1, bytes32("body_invalid"), 0, 0, "");
        assertGt(index.openSince(), 0);
        vm.prank(address(intake));
        index.onOracleFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        assertEq(index.openSince(), 0);
    }

    function test_closeRequestAfterTwoDays() public {
        vm.prank(bob);
        vm.expectRevert(Imdex5.NoRequest.selector);
        index.closeRequest();
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        vm.warp(block.timestamp + 2 days - 1);
        vm.prank(bob);
        vm.expectRevert(Imdex5.TooEarly.selector);
        index.closeRequest();
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        index.closeRequest();
        assertEq(index.openSince(), 0);
    }

    function test_submitStoresTheNextListAndRewards() public {
        uint64[] memory launches = new uint64[](4);
        launches[0] = 2000;
        launches[1] = 1283;
        launches[2] = 737;
        launches[3] = 1175;
        _deliverList(launches);
        Imdex5.Coin[] memory next = index.nextList();
        assertEq(next.length, 4);
        assertEq(next[0].token, NEW_TOKEN);
        assertEq(next[0].hook, HOOK_G);
        assertEq(next[0].launch, 2000);
        assertEq(next[1].token, tokens[1]);
        assertEq(next[1].hook, hooks[1]);
        assertEq(index.answerHash(), bytes32(0));
        assertEq(index.feeImd(), 2e18 - 0.75e18 - 0.25e18);
        assertEq(imd.balanceOf(bob), 10_000e18 + 0.5e18);
        vm.prank(bob);
        vm.expectRevert(Imdex5.ListAwaitsRebalance.selector);
        index.ask();
    }

    function test_submitRejectsWrongAnswerAndForgedSignature() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(2));
        bytes memory sig = _sign(a);
        vm.prank(bob);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(a, sig);
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        OracleAttestation.Attestation memory other = _attestation(_launches(3));
        bytes memory otherSig = _sign(other);
        vm.prank(bob);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(other, otherSig);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, index.attestationDigest(a));
        vm.prank(bob);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, abi.encodePacked(r, s, v));
        vm.prank(bob);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, "");
        // tampering with a signed field breaks the signature
        a.figure = 1;
        vm.prank(bob);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, sig);
        a.figure = 0;
        vm.prank(bob);
        index.submit(a, sig);
        assertEq(index.nextList().length, 2);
        // once
        vm.prank(bob);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(a, sig);
    }

    function test_submitRejectsBadLists() public {
        vm.prank(alice);
        index.fund(100e18);
        bytes32 id;
        uint64[] memory six = new uint64[](6);
        for (uint256 i = 0; i < 6; ++i) {
            six[i] = uint64(1000 + i);
        }
        _expectSubmitRevert(id, _attestation(six), Imdex5.BadList.selector);
        _expectSubmitRevert(id, _attestation(new uint64[](0)), Imdex5.BadList.selector);
        uint64[] memory dup = new uint64[](2);
        dup[0] = 1283;
        dup[1] = 1283;
        _expectSubmitRevert(id, _attestation(dup), Imdex5.BadList.selector);
        uint64[] memory unknown = new uint64[](1);
        unknown[0] = 4242;
        _expectSubmitRevert(id, _attestation(unknown), abi.encodeWithSelector(Imdex5.NotRecorded.selector, 4242));
        regA.record(4243, address(0), HOOK_G);
        unknown[0] = 4243;
        _expectSubmitRevert(id, _attestation(unknown), abi.encodeWithSelector(Imdex5.ArtifactMissing.selector, 4243));
        regA.record(4244, NEW_TOKEN, address(0));
        unknown[0] = 4244;
        _expectSubmitRevert(id, _attestation(unknown), abi.encodeWithSelector(Imdex5.ArtifactMissing.selector, 4244));
        // same token under two launches
        regB.record(4245, NEW_TOKEN, HOOK_G);
        dup[0] = 2000;
        dup[1] = 4245;
        _expectSubmitRevert(id, _attestation(dup), Imdex5.BadList.selector);
        // a value too wide for a launch number
        OracleAttestation.Attestation memory wide = _attestation(unknown);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1) << 64);
        wide.answer = abi.encode(ids);
        _expectSubmitRevert(id, wide, Imdex5.BadList.selector);
        // the wrong answer type
        OracleAttestation.Attestation memory typed = _attestation(_launches(1));
        typed.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        _expectSubmitRevert(
            id,
            typed,
            abi.encodeWithSelector(
                OracleAttestationConsumer.WrongAnswerType.selector,
                OracleAttestation.ANSWER_BYTES32_LIST,
                OracleAttestation.ANSWER_ADDRESS_LIST
            )
        );
    }

    function _expectSubmitRevert(bytes32 id, OracleAttestation.Attestation memory a, bytes4 selector) internal {
        _expectSubmitRevert(id, a, abi.encodePacked(selector));
    }

    /// @dev Opens a fresh request, delivers `a` for it, and expects `submit` to revert with `err`.
    function _expectSubmitRevert(bytes32, OracleAttestation.Attestation memory a, bytes memory err) internal {
        asks += 1;
        vm.warp(1_800_000_000 + asks * 7 days);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), keccak256(a.answer));
        bytes memory sig = _sign(a);
        vm.prank(bob);
        vm.expectRevert(err);
        index.submit(a, sig);
    }

    // ---- rebalance ----
    function test_rebalanceNeedsAList() public {
        vm.prank(bob);
        vm.expectRevert(Imdex5.NoNextList.selector);
        index.rebalance();
    }

    function test_rebalanceSellsAdoptsAndBuys() public {
        _mintFirst(alice, 1000e18);
        uint64[] memory launches = new uint64[](4);
        launches[0] = 1282;
        launches[1] = 1283;
        launches[2] = 2000;
        launches[3] = 737;
        _deliverList(launches);
        uint256 heldD = index.held(tokens[3]);
        uint256 feeBefore = index.feeImd();
        vm.prank(bob);
        index.rebalance();
        Imdex5.Coin[] memory coins = index.coins();
        assertEq(index.listCount(), 4);
        assertEq(coins[2].token, NEW_TOKEN);
        assertEq(index.nextList().length, 0);
        // the 2% limit sells only part of the leavers; they stay as residuals after the list
        assertEq(coins.length, 6);
        assertEq(coins[4].token, tokens[3]);
        assertEq(coins[5].token, tokens[4]);
        assertLt(index.held(tokens[3]), heldD);
        assertGt(index.held(tokens[3]), 0);
        // what the leavers brought was spent on the list
        assertGt(index.held(NEW_TOKEN), 0);
        assertGt(index.held(tokens[0]), COIN_RESERVE * 199e18 / (IMD_RESERVE + 199e18));
        assertEq(index.feeImd(), feeBefore - 0.25e18);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
        for (uint256 i = 0; i < coins.length; ++i) {
            assertEq(MockERC20(coins[i].token).balanceOf(address(index)), index.held(coins[i].token));
        }
        // a second rebalance finishes selling the residuals
        _deliverListAgain(launches);
        vm.prank(bob);
        index.rebalance();
        assertLt(index.held(tokens[3]), heldD / 2);
    }

    function _deliverListAgain(uint64[] memory launches) internal {
        vm.warp(block.timestamp + 7 days);
        _deliverList(launches);
    }

    function test_rebalanceTrimsAHoldingOverAQuarter() public {
        _mintFirst(alice, 1000e18);
        // coin A triples in price: now well over a quarter of total value
        pm.setPool(_key(tokens[0], hooks[0]), 0, 0);
        _setPool(tokens[0], hooks[0], COIN_RESERVE, 3 * IMD_RESERVE);
        uint64[] memory launches = _launches(4);
        _deliverList(launches);
        uint256 heldA = index.held(tokens[0]);
        vm.prank(bob);
        index.rebalance();
        assertLt(index.held(tokens[0]), heldA);
        assertEq(index.listCount(), 4);
    }

    function test_rebalanceSkipsADeadPool() public {
        _mintFirst(alice, 1000e18);
        uint64[] memory launches = _launches(4);
        _deliverList(launches);
        pm.setDead(_key(tokens[4], hooks[4]), true);
        uint256 heldE = index.held(tokens[4]);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.held(tokens[4]), heldE);
        assertEq(index.coins().length, 5);
        assertEq(index.listCount(), 4);
        // the residual is still redeemable
        vm.prank(alice);
        index.redeem(995e18);
        assertEq(MockERC20(tokens[4]).balanceOf(alice), heldE);
    }

    function test_rebalanceSkipsAHookThatLeavesAnUnsettledDelta() public {
        _mintFirst(alice, 1000e18);
        uint64[] memory launches = new uint64[](5);
        launches[0] = 1282;
        launches[1] = 1283;
        launches[2] = 737;
        launches[3] = 1075;
        launches[4] = 2000;
        _deliverList(launches);
        // MARG's hook takes one wei of IMD from the manager for the index's swaps and never
        // settles it; the real manager would revert the whole unlock at its end
        hookM.setMisbehave(hookM.MISBEHAVE_TAKE(), address(index));
        uint256 heldM = index.held(tokens[1]);
        vm.expectEmit(true, false, false, false, address(index));
        emit Imdex5.SwapSkipped(tokens[1], true, 0);
        vm.prank(bob);
        index.rebalance{gas: 30_000_000}();
        assertEq(index.held(tokens[1]), heldM);
        assertEq(index.nextList().length, 0);
        assertEq(index.listCount(), 5);
        assertGt(index.held(NEW_TOKEN), 0);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]));
        }
        // the oracle loop goes on
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
    }

    function test_rebalanceSurvivesAHookThatBurnsAllGas() public {
        _mintFirst(alice, 1000e18);
        // MARG leaves the list and is repriced 5x, so it is sold in step 1 and trimmed in step 3
        pm.setPool(_key(tokens[1], hooks[1]), 0, 0);
        _setPool(tokens[1], hooks[1], COIN_RESERVE, 5 * IMD_RESERVE);
        uint64[] memory launches = new uint64[](4);
        launches[0] = 1282;
        launches[1] = 737;
        launches[2] = 1075;
        launches[3] = 2000;
        _deliverList(launches);
        hookM.setMisbehave(hookM.MISBEHAVE_BURN(), address(index));
        uint256 heldM = index.held(tokens[1]);
        // skipped twice: the step 1 sale and the step 3 trim; the buys of step 4 still run
        vm.expectEmit(true, false, false, true, address(index));
        emit Imdex5.SwapSkipped(tokens[1], false, heldM);
        vm.expectEmit(true, false, false, false, address(index));
        emit Imdex5.SwapSkipped(tokens[1], false, 0);
        vm.prank(bob);
        index.rebalance{gas: 8_000_000}();
        assertEq(index.held(tokens[1]), heldM);
        assertEq(index.listCount(), 4);
        // MARG (unsold) and SC (partly sold under the 2% limit) stay as residuals
        assertEq(index.coins().length, 6);
        assertEq(index.coins()[4].token, tokens[1]);
        assertEq(index.coins()[5].token, tokens[4]);
        // the step 4 buys still ran
        assertGt(index.held(NEW_TOKEN), 0);
        assertEq(index.nextList().length, 0);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
    }

    function test_rebalanceWithNothingHeld() public {
        uint64[] memory launches = _launches(3);
        _deliverList(launches);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.coins().length, 3);
        assertEq(index.listCount(), 3);
        vm.prank(alice);
        index.mintFirst(300e18, new uint256[](3));
        assertEq(index.balanceOf(alice), 298.5e18);
        assertGt(index.held(tokens[2]), 0);
        assertEq(index.held(tokens[3]), 0);
    }

    // ---- attacks ----
    function test_unlockCallbackAndSwapSelfAreNotCallable() public {
        vm.prank(bob);
        vm.expectRevert(Imdex5.OnlyPoolManager.selector);
        index.unlockCallback("");
        vm.prank(address(pm));
        vm.expectRevert(Imdex5.OnlyPoolManager.selector);
        index.unlockCallback(abi.encode(Imdex5.Op.Rebalance, bob, 0, 0, 0, new uint256[](0)));
        vm.prank(bob);
        vm.expectRevert(Imdex5.OnlySelf.selector);
        index.swapSelf(tokens[0], hooks[0], true, 1, false, false);
    }

    function test_hookCannotReenter() public {
        _mintFirst(alice, 1000e18);
        hook.arm(address(index), abi.encodeCall(Imdex5.redeem, (1)));
        vm.prank(alice);
        index.transfer(HOOK_G, 10e18);
        vm.prank(bob);
        index.mint(10e18, 100e18);
        assertGt(hook.attempts(), 0);
        assertFalse(hook.reentered());
        hook.arm(address(index), abi.encodeCall(Imdex5.mint, (1, 1e18)));
        vm.prank(alice);
        index.redeemToImd(10e18, 0);
        assertFalse(hook.reentered());
        hook.arm(
            address(index),
            abi.encodeCall(Imdex5.unlockCallback, (abi.encode(Imdex5.Op.Rebalance, bob, 0, 0, 0, new uint256[](0))))
        );
        _deliverList(_launches(4));
        vm.prank(bob);
        index.rebalance();
        assertFalse(hook.reentered());
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
    }

    function test_feeImdOnlyLeavesForOracleAndRewards() public {
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        index.mint(100e18, 1000e18);
        vm.prank(alice);
        index.redeem(100e18);
        vm.prank(bob);
        index.redeemToImd(50e18, 0);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
        uint256 fees = index.feeImd();
        _deliverList(_launches(4));
        assertEq(index.feeImd(), fees + 2e18 - 1e18);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.feeImd(), fees + 2e18 - 1.25e18);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
    }

    function testFuzz_mintThenRedeemNeverPaysMoreThanDeposited(uint256 first, uint256 shares) public {
        first = bound(first, 1e18, 5000e18);
        _mintFirst(alice, first);
        shares = bound(shares, 1, index.totalSupply());
        vm.prank(bob);
        index.mint(shares, 10_000e18);
        uint256 paid = 10_000e18 - imd.balanceOf(bob);
        assertGe(paid, shares);
        vm.prank(bob);
        index.redeemToImd(shares, 0);
        assertLe(imd.balanceOf(bob), 10_000e18);
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd());
    }
}
