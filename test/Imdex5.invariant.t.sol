// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20, MockIntake, MockPoolManager, ReentrantHook} from "./mocks/Mocks.sol";
import {PoolTaxERC20} from "./mocks/PoolTaxERC20.sol";

/// @dev Drives the index with bounded inputs from three actors, toggles pool and coin failures,
/// runs the oracle round through the mocked Intake, and asserts per-call facts about `feeImd`.
contract Imdex5Handler is CommonBase, StdUtils {
    Imdex5 public index;
    MockERC20 public imd;
    MockPoolManager public pm;
    MockIntake public intake;
    address[] public actors;
    address[] public tokens;
    address[] public hooks;
    uint64[] public launches;
    uint256 immutable KEY_PK;

    // ghosts
    uint256 public ghostFeeOut; // every decrease of feeImd observed
    uint256 public ghostRewards; // 0.25 IMD rewards observed
    uint256 public ghostAsks; // asks that paid the intake
    uint256 public ghostFreeMints; // mints that cost nothing (must stay zero while value is held)
    mapping(bytes32 => uint256) public calls;

    OracleAttestation.Attestation internal pending;
    bool internal hasPending;

    constructor(
        Imdex5 index_,
        MockERC20 imd_,
        MockPoolManager pm_,
        MockIntake intake_,
        address[] memory actors_,
        address[] memory tokens_,
        address[] memory hooks_,
        uint64[] memory launches_,
        uint256 pk
    ) {
        index = index_;
        imd = imd_;
        pm = pm_;
        intake = intake_;
        actors = actors_;
        tokens = tokens_;
        hooks = hooks_;
        launches = launches_;
        KEY_PK = pk;
    }

    // ---- helpers ----
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _key(address token, address hook_) internal view returns (IPoolManager.PoolKey memory) {
        (address c0, address c1) = address(imd) < token ? (address(imd), token) : (token, address(imd));
        return IPoolManager.PoolKey(c0, c1, index.POOL_FEE(), index.TICK_SPACING(), hook_);
    }

    function _feeDelta(uint256 before, uint256 allowedDrop, bool reward) internal {
        uint256 after_ = index.feeImd();
        if (after_ < before) {
            uint256 drop = before - after_;
            require(drop == allowedDrop, "feeImd left by an unexpected amount");
            ghostFeeOut += drop;
            if (reward) ghostRewards += 1;
        }
    }

    // ---- value flows ----
    function fund(uint256 seed, uint256 amount) external {
        calls["fund"]++;
        address who = _actor(seed);
        amount = bound(amount, 1, 50e18);
        if (imd.balanceOf(who) < amount) return;
        uint256 before = index.feeImd();
        vm.prank(who);
        index.fund(amount);
        require(index.feeImd() == before + amount, "fund did not land in feeImd");
    }

    function mintFirst(uint256 seed, uint256 amount) external {
        calls["mintFirst"]++;
        if (index.totalSupply() != 0) return;
        address who = _actor(seed);
        amount = bound(amount, 1, 2000e18);
        if (imd.balanceOf(who) < amount) return;
        uint256[] memory minOut = new uint256[](index.listCount());
        uint256 feeBefore = index.feeImd();
        uint256 imdBefore = imd.balanceOf(who);
        vm.prank(who);
        try index.mintFirst(amount, minOut) {
            uint256 paid = imdBefore - imd.balanceOf(who);
            require(paid == amount, "mintFirst pulled a different amount");
            require(index.totalSupply() < amount, "shares minted at or above the IMD paid");
            require(index.feeImd() > feeBefore, "mintFirst took no fee");
        } catch {}
    }

    function mint(uint256 seed, uint256 shares, uint256 maxIn) external {
        calls["mint"]++;
        uint256 supply = index.totalSupply();
        if (supply == 0) return;
        address who = _actor(seed);
        shares = bound(shares, 1, supply * 2 + 1);
        maxIn = bound(maxIn, 0, imd.balanceOf(who));
        uint256 feeBefore = index.feeImd();
        uint256 imdBefore = imd.balanceOf(who);
        uint256 sharesBefore = index.balanceOf(who);
        uint256[] memory heldBefore = new uint256[](tokens.length);
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        uint256 idleBefore = index.idleImd();
        bool holdsValue = idleBefore > 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            heldBefore[i] = index.held(tokens[i]);
            balancesBefore[i] = MockERC20(tokens[i]).balanceOf(address(index));
            holdsValue = holdsValue || heldBefore[i] > 0;
        }
        vm.prank(who);
        try index.mint(shares, maxIn) {
            uint256 paid = imdBefore - imd.balanceOf(who);
            uint256 minted = index.balanceOf(who) - sharesBefore;
            require(minted > 0 && minted <= shares, "invalid shares minted");
            uint256 expected = shares;
            for (uint256 i; i < tokens.length; ++i) {
                uint256 need = Math.mulDiv(heldBefore[i], shares, supply, Math.Rounding.Ceil);
                if (need == 0) continue;
                uint256 received = MockERC20(tokens[i]).balanceOf(address(index)) - balancesBefore[i];
                expected = Math.min(expected, Math.mulDiv(shares, received, need));
                require(heldBefore[i] * minted <= received * supply, "mint diluted an existing holding");
            }
            require(minted == expected, "wrong delivered fraction minted");
            require(
                index.idleImd() - idleBefore == Math.mulDiv(idleBefore, minted, supply, Math.Rounding.Ceil),
                "idle charged other than the issued shares' fraction"
            );
            require(paid <= maxIn, "mint pulled more than maxImdIn");
            require(index.feeImd() >= feeBefore, "mint reduced feeImd");
            if (paid == 0) ghostFreeMints += 1;
            require(holdsValue, "a mint succeeded while the index held nothing");
        } catch {}
    }

    function redeem(uint256 seed, uint256 shares) external {
        calls["redeem"]++;
        address who = _actor(seed);
        uint256 bal = index.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        uint256 feeBefore = index.feeImd();
        vm.prank(who);
        index.redeem(shares);
        require(index.feeImd() == feeBefore, "redeem touched feeImd");
        require(index.balanceOf(who) == bal - shares, "redeem burned the wrong amount");
    }

    function redeemToImd(uint256 seed, uint256 shares) external {
        calls["redeemToImd"]++;
        address who = _actor(seed);
        uint256 bal = index.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        uint256 feeBefore = index.feeImd();
        vm.prank(who);
        try index.redeemToImd(shares, 0) {
            require(index.feeImd() >= feeBefore, "redeemToImd reduced feeImd");
            require(index.balanceOf(who) == bal - shares, "redeemToImd burned the wrong amount");
        } catch {}
    }

    function claim(uint256 seed, uint256 coin) external {
        calls["claim"]++;
        address who = _actor(seed);
        address token = coin % (tokens.length + 1) == tokens.length ? address(imd) : tokens[coin % tokens.length];
        uint256 owedBefore = index.owed(who, token);
        uint256 balBefore = MockERC20(token).balanceOf(who);
        vm.prank(who);
        try index.claim(token) {
            require(owedBefore > 0, "claim paid with nothing owed");
            require(index.owed(who, token) == 0, "claim left a debt");
            require(MockERC20(token).balanceOf(who) == balBefore + owedBefore, "claim paid the wrong amount");
        } catch {}
    }

    function transferShares(uint256 seed, uint256 to, uint256 amount) external {
        calls["transfer"]++;
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        index.transfer(_actor(to), amount);
    }

    // ---- the world ----
    function togglePool(uint256 coin, bool dead) external {
        calls["togglePool"]++;
        coin = coin % tokens.length;
        pm.setDead(_key(tokens[coin], hooks[coin]), dead);
    }

    function setCoinFailMode(uint256 coin, uint8 mode) external {
        calls["failMode"]++;
        coin = coin % tokens.length;
        MockERC20(tokens[coin]).setFailMode(mode % 4);
    }

    /// @dev Caps what a pool takes in one exact-input swap (0 lifts the cap): partial fills.
    function setPoolMaxIn(uint256 coin, uint256 maxIn) external {
        calls["maxIn"]++;
        coin = coin % tokens.length;
        pm.setMaxIn(_key(tokens[coin], hooks[coin]), bound(maxIn, 0, 500e18));
    }

    /// @dev The shared hook misbehaves for the index's swaps only: takes and never settles,
    /// or burns every gas it is given. 0 restores it.
    function setHookMisbehave(uint8 mode) external {
        calls["hookMisbehave"]++;
        ReentrantHook(hooks[0]).setMisbehave(mode % 3, address(index));
    }

    function warp(uint256 seconds_) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(seconds_, 1, 8 days));
    }

    // ---- the oracle round ----
    function ask(uint256 seed) external {
        calls["ask"]++;
        address who = _actor(seed);
        uint256 feeBefore = index.feeImd();
        uint256 count = intake.count();
        uint256 whoBefore = imd.balanceOf(who);
        vm.prank(who);
        try index.ask() {
            if (intake.count() == count + 1) {
                require(index.feeImd() == feeBefore - 0.75e18, "ask spent other than 0.75 IMD");
                require(imd.balanceOf(who) == whoBefore + 0.25e18, "ask paid the caller other than 0.25");
                require(imd.balanceOf(address(intake)) == 0.5e18 * intake.count(), "intake paid wrong");
                ghostFeeOut += 0.75e18;
                ghostAsks += 1;
            } else {
                require(index.feeImd() == feeBefore, "a returned ask moved fees");
                require(feeBefore < 0.75e18, "ask returned with enough fees");
            }
        } catch {}
    }

    function deliverResult(uint256 listSeed, uint256 n, uint16 agreed) external {
        calls["deliverResult"]++;
        if (index.openSince() == 0) return;
        n = bound(n, 1, 5);
        uint64[] memory list = new uint64[](n);
        uint256 picked = 0;
        for (uint256 i = 0; i < launches.length && picked < n; ++i) {
            if ((listSeed >> i) & 1 == 1 || launches.length - i <= n - picked) {
                list[picked++] = launches[i];
            }
        }
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = bytes32(uint256(list[i]));
        }
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("uuid", intake.count())),
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
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 86_400)
        });
        bytes32 id = intake.lastRequestId();
        uint256 imdBefore = imd.balanceOf(address(index));
        vm.prank(address(intake));
        index.onOracleResult{gas: 200_000}(id, a, "");
        require(imd.balanceOf(address(index)) == imdBefore, "the callback moved IMD");
        if (agreed >= 4) {
            require(index.answerHash() == keccak256(a.answer), "the answer was not stored");
            require(index.openSince() == 0, "the request stayed open");
            pending = a;
            hasPending = true;
        } else {
            require(index.openSince() != 0, "a thin panel closed the request");
        }
    }

    function deliverFailure() external {
        calls["deliverFailure"]++;
        if (index.openSince() == 0) return;
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleFailure(id, 2, bytes32("disagreed"), 2, 5, "");
        require(index.openSince() == 0, "failure did not close");
    }

    function closeRequest(uint256 seed) external {
        calls["closeRequest"]++;
        vm.prank(_actor(seed));
        try index.closeRequest() {
            require(index.openSince() == 0);
        } catch {}
    }

    function submit(uint256 seed) external {
        calls["submit"]++;
        if (!hasPending) return;
        if (index.answerHash() != keccak256(pending.answer)) {
            hasPending = false;
            return;
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, index.attestationDigest(pending));
        bytes memory sig = abi.encodePacked(r, s, v);
        address who = _actor(seed);
        uint256 feeBefore = index.feeImd();
        vm.prank(who);
        index.submit(pending, sig);
        hasPending = false;
        require(index.answerHash() == 0, "answer hash not cleared");
        require(index.nextList().length >= 1 && index.nextList().length <= 5, "bad next list");
        _feeDelta(feeBefore, 0.25e18, true);
    }

    function rebalance(uint256 seed) external {
        calls["rebalance"]++;
        if (index.nextList().length == 0) return;
        address who = _actor(seed);
        uint256 feeBefore = index.feeImd();
        vm.prank(who);
        index.rebalance();
        require(index.nextList().length == 0, "next list not consumed");
        _feeDelta(feeBefore, 0.25e18, true);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}

/// @title Invariants over random call sequences
contract Imdex5InvariantTest is Imdex5Base {
    Imdex5Handler handler;
    uint256 initialActorImd;
    uint256 initialPoolImd;

    function setUp() public virtual {
        _deployAll();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        handler = new Imdex5Handler(index, imd, pm, intake, actors, tokens, hooks, launches, KEY_PK);
        initialActorImd = 30_000e18;
        initialPoolImd = imd.balanceOf(address(pm));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.mintFirst.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.redeemToImd.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.transferShares.selector;
        selectors[7] = handler.togglePool.selector;
        selectors[8] = handler.setCoinFailMode.selector;
        selectors[9] = handler.warp.selector;
        selectors[10] = handler.ask.selector;
        selectors[11] = handler.deliverResult.selector;
        selectors[12] = handler.deliverFailure.selector;
        selectors[13] = handler.closeRequest.selector;
        selectors[14] = handler.submit.selector;
        selectors[15] = handler.rebalance.selector;
        selectors[16] = handler.mint.selector;
        selectors[17] = handler.setPoolMaxIn.selector;
        selectors[18] = handler.setHookMisbehave.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _owedTotal(address token) internal view returns (uint256 total) {
        total = index.owed(alice, token) + index.owed(bob, token) + index.owed(carol, token);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_imdBalanceIsIdlePlusFeePlusOwed() public view {
        assertEq(
            imd.balanceOf(address(index)),
            index.idleImd() + index.feeImd() + _owedTotal(address(imd)),
            "IMD balance != idleImd + feeImd + owed"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_coinBalancesAreHeldPlusOwed() public view {
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
    function invariant_zeroSupplyMeansNothingHeld() public view {
        if (index.totalSupply() != 0) return;
        assertEq(index.idleImd(), 0, "idle IMD with no shares");
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(index.held(tokens[i]), 0, "coins held with no shares");
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorsNeverExtractMoreImdThanTheyPutIn() public view {
        uint256 actorsNow = imd.balanceOf(alice) + imd.balanceOf(bob) + imd.balanceOf(carol);
        assertLe(actorsNow, initialActorImd, "the actors as a group gained IMD");
        assertGe(imd.balanceOf(address(pm)), initialPoolImd, "the pools lost IMD to the index");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feeImdLeavesOnlyForTheOracleAndRewards() public view {
        assertEq(
            handler.ghostFeeOut(),
            handler.ghostAsks() * 0.75e18 + handler.ghostRewards() * 0.25e18,
            "feeImd left by another path"
        );
        assertEq(imd.balanceOf(address(intake)), handler.ghostAsks() * 0.5e18, "the intake got other than 0.5 per ask");
        assertLe(index.feeImd(), imd.balanceOf(address(index)), "feeImd not backed");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noFreeMintWhileValueIsHeld() public view {
        assertEq(handler.ghostFreeMints(), 0, "a mint cost nothing while the index held value");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_listShape() public view {
        Imdex5.Coin[] memory coins = index.coins();
        uint256 n = index.listCount();
        assertGe(n, 1);
        assertLe(n, 5);
        assertGe(coins.length, n, "list longer than holdings");
        assertLe(index.nextList().length, 5);
        for (uint256 i = 0; i < coins.length; ++i) {
            assertTrue(coins[i].token != address(0) && coins[i].hook != address(0));
            for (uint256 j = i + 1; j < coins.length; ++j) {
                assertTrue(coins[i].token != coins[j].token, "duplicate coin");
            }
        }
        // every coin with a holding is in the list or kept as a residual
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (index.held(tokens[i]) == 0) continue;
            bool found;
            for (uint256 j = 0; j < coins.length && !found; ++j) {
                found = coins[j].token == tokens[i];
            }
            assertTrue(found, "a holding fell out of the list");
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_requestStateIsConsistent() public view {
        if (index.openSince() != 0) {
            assertEq(index.openRequest(), intake.lastRequestId(), "an open request is not the intake's last");
            assertLe(index.openSince(), block.timestamp);
        }
        assertLe(index.lastAsk(), block.timestamp);
    }
}

/// @dev Keep all original invariants and also exercise them with the starting list's 2% tax.
contract Imdex5TaxedCoinInvariantTest is Imdex5InvariantTest {
    function setUp() public override {
        super.setUp();
        vm.etch(tokens[4], address(new PoolTaxERC20(address(pm))).code);
    }
}
