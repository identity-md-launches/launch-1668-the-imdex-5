// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IIntake, IPoolManager, IRegistry, IUnlockCallback} from "./Interfaces.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";

/// @title The Imdex 5
/// @notice An index of the five largest tokens paired with IMD on Ethereum mainnet. The contract's
/// own ERC-20 is the share. Anyone may call anything; there is no owner, role, setting, pause or
/// upgrade. Accounting is internal: `held` per coin, `idleImd` (the holders' unspent IMD) and
/// `feeImd` (fees, which only ever pay the oracle price and caller rewards).
contract Imdex5 is ERC20, ReentrancyGuard, OracleAttestationConsumer, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ---- the chain ----
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    IRegistry public constant REGISTRY_A = IRegistry(0xA47FcB220DDd1cDddA865F89029BEc1b9EcA3bf1);
    IRegistry public constant REGISTRY_B = IRegistry(0x7c9D5ee697BfF5Ac4F10E2E54d3f40c44e48fE23);
    address public constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    // ---- the terms ----
    uint256 public constant ORACLE_PRICE = 0.5e18;
    uint256 public constant REWARD = 0.25e18;
    uint256 public constant FEE_BPS = 50;
    uint256 public constant BPS = 10_000;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint64 public constant ASK_INTERVAL = 7 days;
    uint64 public constant CLOSE_AFTER = 2 days;
    uint16 public constant MIN_AGREED = 4;
    uint256 public constant MAX_LIST = 5;
    /// @dev A holding is capped at a quarter of total value in a rebalance.
    uint256 public constant WEIGHT_DIVISOR = 4;
    /// @dev A limited swap stops where the sqrt price has moved 1% (the price about 2%).
    uint256 public constant SQRT_UP_BPS = 10_100;
    uint256 public constant SQRT_DOWN_BPS = 9_900;
    /// @dev Gas given to one skippable swap (`swapSelf`) and to one coin payment (`_pay`), so a
    /// hook or coin that burns everything it is given cannot starve the rest of the call.
    uint256 public constant SWAP_GAS = 1_000_000;
    uint256 public constant PAY_GAS = 300_000;
    /// @dev Uniswap v4 PoolManager: `_pools` is storage slot 6; `slot0` holds sqrtPriceX96 low.
    uint256 private constant POOLS_SLOT = 6;
    /// @dev Uniswap v4 PoolManager: the transient count of addresses with an unsettled delta,
    /// `uint256(keccak256("NonzeroDeltaCount")) - 1`.
    bytes32 private constant NONZERO_DELTA_COUNT_SLOT =
        0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    uint160 private constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 private constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    uint256 private constant Q96 = 2 ** 96;

    string private constant QUESTION =
        "Which launch numbers identify the five tokens, recorded in either IdentityMD launch registry 0xA47FcB220DDd1cDddA865F89029BEc1b9EcA3bf1 or 0x7c9D5ee697BfF5Ac4F10E2E54d3f40c44e48fE23 on Ethereum (chain id 1), whose Uniswap v4 pool against IMD 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7 (fee 12500) holds 100 IMD or more at the close of the window, ranked by spot price in IMD times total supply, largest first? Exclude USDC, USDT and imdUSD. Answer with the launch numbers as bytes32 values, largest first.";

    struct Coin {
        address token;
        address hook;
        uint64 launch;
    }

    enum Op {
        MintFirst,
        Mint,
        RedeemToImd,
        Rebalance
    }

    // ---- state ----
    /// @dev The adopted list first (`listCount` entries), then coins a rebalance could not fully sell.
    Coin[] private _coins;
    uint256 public listCount;
    Coin[] private _nextList;
    mapping(address coin => uint256) public held;
    mapping(address account => mapping(address coin => uint256)) public owed;
    uint256 public idleImd;
    uint256 public feeImd;
    bytes32 public openRequest;
    uint64 public openSince;
    uint64 public lastAsk;
    bytes32 public answerHash;

    // ---- errors ----
    error OnlyPoolManager();
    error OnlySelf();
    error ZeroAmount();
    error NotFirstMint();
    error FirstMintOnly();
    error BadLength();
    error BuyFailed(address coin);
    error TooExpensive(uint256 cost);
    error NothingToPay();
    error TooLittleOut(uint256 out);
    error NothingOwed();
    error RequestOpen();
    error ListAwaitsRebalance();
    error AskTooSoon();
    error NoRequest();
    error TooEarly();
    error WrongAnswer();
    error BadList();
    error NotRecorded(uint64 launch);
    error ArtifactMissing(uint64 launch);
    error NoNextList();
    error BadDelta();

    // ---- events ----
    event Funded(address indexed from, uint256 amount);
    event MintedFirst(address indexed to, uint256 imdIn, uint256 shares);
    event Minted(address indexed to, uint256 shares, uint256 imdPaid);
    event Redeemed(address indexed from, uint256 shares);
    event RedeemedToImd(address indexed from, uint256 shares, uint256 imdOut);
    event Paid(address indexed to, address indexed coin, uint256 amount);
    event Owed(address indexed to, address indexed coin, uint256 amount);
    event Claimed(address indexed to, address indexed coin, uint256 amount);
    event Swapped(address indexed coin, bool buy, uint256 amountIn, uint256 amountOut);
    event SwapSkipped(address indexed coin, bool buy, uint256 amount);
    event Asked(bytes32 indexed requestId, address indexed caller);
    event Answered(bytes32 indexed requestId, bytes32 answerHash);
    event RequestFailed(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event RequestClosed(bytes32 indexed requestId);
    event ListSubmitted(address indexed caller, uint64[] launches);
    event Rebalanced(address indexed caller);
    event RewardPaid(address indexed to, uint256 amount);

    constructor() ERC20("The Imdex 5", "IMDEX5") OracleAttestationConsumer(ORACLE_SIGNER) {
        address g = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
        _coins.push(Coin(0x53d0eA0A685220718Dc6a0a6e4617194C6F37921, g, 1282));
        _coins.push(Coin(0xfA0EfEa559bdE229031c2B0A219472316647759c, 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc, 1283));
        _coins.push(Coin(0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e, g, 737));
        _coins.push(Coin(0x54C68a4D0A21DBb1ad72FaA052db159d26F967EA, g, 1075));
        _coins.push(Coin(0x1ae93A4D9CC0b41C594D00387B6F832a88f729b7, g, 1175));
        listCount = 5;
    }

    // ---- views ----
    function coins() external view returns (Coin[] memory) {
        return _coins;
    }

    function nextList() external view returns (Coin[] memory) {
        return _nextList;
    }

    /// @notice The oracle request body, built on chain.
    function body() public view returns (bytes memory) {
        return abi.encodePacked(
            '{"v":1,"question":"',
            QUESTION,
            '","chainId":1,"window":{"hours":24},"answerType":"bytes32[]","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":86400,"head":5,"consumer":{"chainId":1,"verifyingContract":"',
            Strings.toHexString(address(this)),
            '"}}'
        );
    }

    // ---- fees ----
    /// @notice Anyone adds IMD to `feeImd`.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(IMD).safeTransferFrom(msg.sender, address(this), amount);
        feeImd += amount;
        emit Funded(msg.sender, amount);
    }

    // ---- mint ----
    /// @notice The first mint: 0.50% to `feeImd`, the rest buys the list in equal IMD parts,
    /// one share per IMD of the rest; what a pool could not take stays as the holders' idle IMD.
    /// Reverts if a buy fails, returns nothing or returns under its `minOut`.
    function mintFirst(uint256 imdIn, uint256[] calldata minOut) external nonReentrant {
        if (totalSupply() != 0) revert NotFirstMint();
        if (imdIn == 0) revert ZeroAmount();
        if (minOut.length != listCount) revert BadLength();
        IERC20(IMD).safeTransferFrom(msg.sender, address(this), imdIn);
        IPoolManager(POOL_MANAGER).unlock(abi.encode(Op.MintFirst, msg.sender, imdIn, 0, 0, minOut));
    }

    /// @notice Mints up to `shares` by buying the proportional amount of every coin, plus the
    /// idle IMD proportional to the shares issued, plus 0.50% of the buys' cost as fee. `maxImdIn`
    /// is pulled first and the unspent part refunded. Short fills reduce shares to the least
    /// delivered fraction; every buy is still paid. Reverts if the cost exceeds the limit, is
    /// nothing, a buy fails, a buy delivers nothing, or the delivered fraction rounds to zero shares.
    function mint(uint256 shares, uint256 maxImdIn) external nonReentrant {
        if (totalSupply() == 0) revert FirstMintOnly();
        if (shares == 0) revert ZeroAmount();
        IERC20(IMD).safeTransferFrom(msg.sender, address(this), maxImdIn);
        IPoolManager(POOL_MANAGER).unlock(abi.encode(Op.Mint, msg.sender, shares, maxImdIn, 0, new uint256[](0)));
    }

    // ---- redeem ----
    /// @notice Burns `shares` and pays 99.50% of the proportional holdings in kind (100% when the
    /// supply reaches zero). No price, no trade. A coin whose transfer fails becomes owed.
    function redeem(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        uint256 keepBps = supply == shares ? BPS : BPS - FEE_BPS;
        uint256 n = _coins.length;
        uint256[] memory amounts = new uint256[](n + 1);
        for (uint256 i = 0; i < n; ++i) {
            address token = _coins[i].token;
            uint256 amount = Math.mulDiv(held[token], shares * keepBps, supply * BPS);
            held[token] -= amount;
            amounts[i] = amount;
        }
        uint256 idlePart = Math.mulDiv(idleImd, shares * keepBps, supply * BPS);
        idleImd -= idlePart;
        amounts[n] = idlePart;
        for (uint256 i = 0; i < n; ++i) {
            _pay(_coins[i].token, msg.sender, amounts[i]);
        }
        _pay(IMD, msg.sender, idlePart);
        emit Redeemed(msg.sender, shares);
    }

    /// @notice Burns `shares`, sells the proportional holdings, adds the proportional idle IMD,
    /// keeps 0.50% as fee and pays the rest in IMD. A coin whose sale fails is paid in kind under
    /// the redeem rule (99.50%, all of it when the supply reaches zero).
    function redeemToImd(uint256 shares, uint256 minImdOut) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        IPoolManager(POOL_MANAGER)
            .unlock(abi.encode(Op.RedeemToImd, msg.sender, shares, minImdOut, supply, new uint256[](0)));
    }

    /// @notice Takes a coin a redeem could not transfer.
    function claim(address coin) external nonReentrant {
        uint256 amount = owed[msg.sender][coin];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender][coin] = 0;
        IERC20(coin).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, coin, amount);
    }

    // ---- oracle ----
    /// @notice Asks the oracle for the next list. Returns without asking under 0.75 IMD of fees.
    function ask() external nonReentrant {
        if (openSince != 0) revert RequestOpen();
        if (_nextList.length != 0) revert ListAwaitsRebalance();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < lastAsk + ASK_INTERVAL) revert AskTooSoon();
        if (feeImd < ORACLE_PRICE + REWARD) return;
        feeImd -= ORACLE_PRICE + REWARD;
        lastAsk = uint64(block.timestamp);
        openSince = uint64(block.timestamp);
        // an answer of the previous cycle nobody submitted is stale once a new request opens
        answerHash = 0;
        IERC20(IMD).forceApprove(INTAKE, ORACLE_PRICE);
        bytes32 requestId = IIntake(INTAKE)
            .requestWithFailure(
                ACTION,
                body(),
                IIntake.Callback(address(this), this.onOracleResult.selector),
                this.onOracleFailure.selector,
                IMD,
                ORACLE_PRICE
            );
        openRequest = requestId;
        IERC20(IMD).safeTransfer(msg.sender, REWARD);
        emit RewardPaid(msg.sender, REWARD);
        emit Asked(requestId, msg.sender);
    }

    /// @notice The Intake's callback: stores the answer's hash for the open request and closes it.
    /// Never reverts and moves nothing; the signature is checked at `submit`.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata)
        external
        nonReentrant
    {
        if (msg.sender != INTAKE || openSince == 0 || requestId != openRequest || a.agreed < MIN_AGREED) {
            return;
        }
        bytes32 hash = keccak256(a.answer);
        answerHash = hash;
        openSince = 0;
        emit Answered(requestId, hash);
    }

    /// @notice The Intake's failure callback: closes the open request.
    function onOracleFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        nonReentrant
    {
        if (msg.sender != INTAKE || openSince == 0 || requestId != openRequest) return;
        openSince = 0;
        emit RequestFailed(requestId, status, reason);
    }

    /// @notice Anyone closes a request open for two days.
    function closeRequest() external nonReentrant {
        if (openSince == 0) revert NoRequest();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < openSince + CLOSE_AFTER) revert TooEarly();
        openSince = 0;
        emit RequestClosed(openRequest);
    }

    /// @notice Presents the signed attestation whose answer the Intake delivered. Decodes one to
    /// five distinct launch numbers, reads each token and hook from the registry that records it,
    /// and stores them as the next list.
    function submit(OracleAttestation.Attestation calldata a, bytes calldata signature) external nonReentrant {
        if (answerHash == 0 || keccak256(a.answer) != answerHash) revert WrongAnswer();
        if (!SignatureChecker.isValidSignatureNowCalldata(oracleSigner, attestationDigest(a), signature)) {
            revert BadSignature();
        }
        bytes32[] memory ids = decodeBytes32List(a);
        uint256 n = ids.length;
        if (n == 0 || n > MAX_LIST) revert BadList();
        answerHash = 0;
        delete _nextList;
        uint64[] memory launches = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (uint256(ids[i]) > type(uint64).max) revert BadList();
            uint64 launch = uint64(uint256(ids[i]));
            (address token, address hook) = _lookup(launch);
            for (uint256 j = 0; j < i; ++j) {
                if (_nextList[j].launch == launch || _nextList[j].token == token) revert BadList();
            }
            _nextList.push(Coin(token, hook, launch));
            launches[i] = launch;
        }
        emit ListSubmitted(msg.sender, launches);
        _reward(msg.sender);
    }

    /// @notice Moves the index to the next list: sells what leaves, adopts, trims any holding over
    /// a quarter of total value, then spends idle IMD on the list in equal parts.
    function rebalance() external nonReentrant {
        if (_nextList.length == 0) revert NoNextList();
        IPoolManager(POOL_MANAGER).unlock(abi.encode(Op.Rebalance, msg.sender, 0, 0, 0, new uint256[](0)));
        emit Rebalanced(msg.sender);
        _reward(msg.sender);
    }

    // ---- Uniswap v4 ----
    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || !_reentrancyGuardEntered()) revert OnlyPoolManager();
        (Op op, address caller, uint256 a, uint256 b, uint256 c, uint256[] memory arr) =
            abi.decode(data, (Op, address, uint256, uint256, uint256, uint256[]));
        if (op == Op.MintFirst) _mintFirst(caller, a, arr);
        else if (op == Op.Mint) _mintMore(caller, a, b);
        else if (op == Op.RedeemToImd) _redeemToImd(caller, a, b, c);
        else _rebalance();
        return "";
    }

    /// @notice One swap, settled, as an external call so a failing one can be skipped: the callers
    /// give it `SWAP_GAS`, and it fails if any address is left with an unsettled delta. Only this
    /// contract calls it, from inside its own unlock.
    function swapSelf(address token, address hook, bool buy, uint256 amount, bool exactOut, bool limited)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        return _swap(token, hook, buy, amount, exactOut, limited);
    }

    // ---- internals: operations ----
    function _mintFirst(address caller, uint256 imdIn, uint256[] memory minOut) private {
        uint256 fee = Math.mulDiv(imdIn, FEE_BPS, BPS, Math.Rounding.Ceil);
        feeImd += fee;
        uint256 rest = imdIn - fee;
        uint256 n = listCount;
        uint256 part = rest / n;
        uint256 spent = 0;
        for (uint256 i = 0; i < n; ++i) {
            Coin memory coin = _coins[i];
            (uint256 amountIn, uint256 out) = _swap(coin.token, coin.hook, true, part, false, false);
            if (out == 0) revert BuyFailed(coin.token);
            if (out < minOut[i]) revert TooLittleOut(out);
            spent += amountIn;
            held[coin.token] += out;
        }
        // the division's remainder and whatever a pool could not take stay the holders' idle IMD
        idleImd += rest - spent;
        _mint(caller, rest);
        emit MintedFirst(caller, imdIn, rest);
    }

    function _mintMore(address caller, uint256 shares, uint256 maxImdIn) private {
        uint256 supply = totalSupply();
        uint256 minted = shares;
        uint256 cost = 0;
        uint256 n = _coins.length;
        for (uint256 i = 0; i < n; ++i) {
            Coin memory coin = _coins[i];
            uint256 need = Math.mulDiv(held[coin.token], shares, supply, Math.Rounding.Ceil);
            if (need == 0) continue;
            (uint256 amountIn, uint256 out) = _swap(coin.token, coin.hook, true, need, true, false);
            if (out < need) {
                minted = Math.min(minted, Math.mulDiv(shares, out, need));
                if (minted == 0) revert BuyFailed(coin.token);
            }
            cost += amountIn;
            held[coin.token] += out;
        }
        uint256 idlePart = Math.mulDiv(idleImd, minted, supply, Math.Rounding.Ceil);
        idleImd += idlePart;
        uint256 fee = Math.mulDiv(cost, FEE_BPS, BPS, Math.Rounding.Ceil);
        feeImd += fee;
        uint256 total = cost + idlePart + fee;
        if (total == 0) revert NothingToPay();
        if (total > maxImdIn) revert TooExpensive(total);
        _mint(caller, minted);
        if (maxImdIn > total) IERC20(IMD).safeTransfer(caller, maxImdIn - total);
        emit Minted(caller, minted, total);
    }

    function _redeemToImd(address caller, uint256 shares, uint256 minImdOut, uint256 supply) private {
        uint256 proceeds = 0;
        uint256 keepBps = supply == shares ? BPS : BPS - FEE_BPS;
        uint256 n = _coins.length;
        for (uint256 i = 0; i < n; ++i) {
            Coin memory coin = _coins[i];
            uint256 amount = Math.mulDiv(held[coin.token], shares, supply);
            if (amount == 0) continue;
            held[coin.token] -= amount;
            try this.swapSelf{gas: SWAP_GAS}(coin.token, coin.hook, false, amount, false, false) returns (
                uint256 amountIn, uint256 sold
            ) {
                proceeds += sold;
                if (amountIn < amount) _payInKind(coin.token, caller, amount - amountIn, keepBps);
            } catch {
                emit SwapSkipped(coin.token, false, amount);
                _payInKind(coin.token, caller, amount, keepBps);
            }
        }
        uint256 idlePart = Math.mulDiv(idleImd, shares, supply);
        idleImd -= idlePart;
        proceeds += idlePart;
        uint256 fee = Math.mulDiv(proceeds, FEE_BPS, BPS, Math.Rounding.Ceil);
        feeImd += fee;
        uint256 out = proceeds - fee;
        if (out < minImdOut) revert TooLittleOut(out);
        IERC20(IMD).safeTransfer(caller, out);
        emit RedeemedToImd(caller, shares, out);
    }

    function _rebalance() private {
        Coin[] memory old = _coins;
        Coin[] memory next = _nextList;
        // (1) sell every coin not in the next list
        for (uint256 i = 0; i < old.length; ++i) {
            if (_inList(next, old[i].token)) continue;
            uint256 h = held[old[i].token];
            if (h > 0) _trySell(old[i], h);
        }
        // (2) adopt the list; keep what step 1 could not fully sell
        delete _coins;
        for (uint256 i = 0; i < next.length; ++i) {
            _coins.push(next[i]);
        }
        listCount = next.length;
        for (uint256 i = 0; i < old.length; ++i) {
            if (!_inList(next, old[i].token) && held[old[i].token] > 0) _coins.push(old[i]);
        }
        delete _nextList;
        // (3) trim any holding above a quarter of total value, by prices read now
        uint256 n = _coins.length;
        uint256[] memory sqrtP = new uint256[](n);
        uint256 total = idleImd;
        for (uint256 i = 0; i < n; ++i) {
            sqrtP[i] = _sqrtPrice(_key(_coins[i].token, _coins[i].hook));
            total += _value(_coins[i].token, sqrtP[i]);
        }
        uint256 cap = total / WEIGHT_DIVISOR;
        if (listCount >= 4) {
            for (uint256 i = 0; i < n; ++i) {
                Coin memory coin = _coins[i];
                uint256 value = _value(coin.token, sqrtP[i]);
                if (value <= cap) continue;
                uint256 h = held[coin.token];
                _trySell(coin, h - Math.mulDiv(h, cap, value));
            }
        }
        // (4) spend idle IMD on the list in equal parts, up to a quarter weight each
        uint256 part = idleImd / listCount;
        for (uint256 i = 0; i < listCount; ++i) {
            Coin memory coin = _coins[i];
            uint256 value = _value(coin.token, sqrtP[i]);
            uint256 room = cap > value ? cap - value : 0;
            uint256 spend = part < room ? part : room;
            if (spend > 0) _tryBuy(coin, spend);
        }
    }

    // ---- internals: swaps ----
    function _trySell(Coin memory coin, uint256 amount) private {
        try this.swapSelf{gas: SWAP_GAS}(coin.token, coin.hook, false, amount, false, true) returns (
            uint256 amountIn, uint256 out
        ) {
            held[coin.token] -= amountIn;
            idleImd += out;
        } catch {
            emit SwapSkipped(coin.token, false, amount);
        }
    }

    function _tryBuy(Coin memory coin, uint256 imdAmount) private {
        try this.swapSelf{gas: SWAP_GAS}(coin.token, coin.hook, true, imdAmount, false, true) returns (
            uint256 amountIn, uint256 out
        ) {
            idleImd -= amountIn;
            held[coin.token] += out;
        } catch {
            emit SwapSkipped(coin.token, true, imdAmount);
        }
    }

    function _swap(address token, address hook, bool buy, uint256 amount, bool exactOut, bool limited)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        IPoolManager.PoolKey memory key = _key(token, hook);
        bool zeroForOne = buy ? key.currency0 == IMD : key.currency0 == token;
        uint160 limit = zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
        if (limited) {
            uint256 p = _sqrtPrice(key);
            uint256 moved = zeroForOne ? p * SQRT_DOWN_BPS / BPS : p * SQRT_UP_BPS / BPS;
            if (zeroForOne ? moved > MIN_SQRT_PRICE : moved < MAX_SQRT_PRICE) limit = uint160(moved);
        }
        int256 delta = IPoolManager(POOL_MANAGER)
            .swap(key, IPoolManager.SwapParams(zeroForOne, exactOut ? int256(amount) : -int256(amount), limit), "");
        int256 d0 = delta >> 128;
        int256 d1 = int256(int128(delta));
        (int256 dIn, int256 dOut) = zeroForOne ? (d0, d1) : (d1, d0);
        if (dIn > 0 || dOut < 0) revert BadDelta();
        amountIn = uint256(-dIn);
        amountOut = uint256(dOut);
        address inCur = zeroForOne ? key.currency0 : key.currency1;
        address outCur = zeroForOne ? key.currency1 : key.currency0;
        if (amountIn > 0) {
            IPoolManager(POOL_MANAGER).sync(inCur);
            IERC20(inCur).safeTransfer(POOL_MANAGER, amountIn);
            IPoolManager(POOL_MANAGER).settle();
        }
        if (amountOut > 0) {
            uint256 before = IERC20(outCur).balanceOf(address(this));
            IPoolManager(POOL_MANAGER).take(outCur, address(this), amountOut);
            amountOut = IERC20(outCur).balanceOf(address(this)) - before;
        }
        // a hook that left its own delta unsettled would revert the whole unlock later; fail here
        if (IPoolManager(POOL_MANAGER).exttload(NONZERO_DELTA_COUNT_SLOT) != 0) revert BadDelta();
        emit Swapped(token, buy, amountIn, amountOut);
    }

    function _key(address token, address hook) private pure returns (IPoolManager.PoolKey memory) {
        (address c0, address c1) = IMD < token ? (IMD, token) : (token, IMD);
        return IPoolManager.PoolKey(c0, c1, POOL_FEE, TICK_SPACING, hook);
    }

    function _sqrtPrice(IPoolManager.PoolKey memory key) private view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(keccak256(abi.encode(key)), POOLS_SLOT));
        return uint256(uint160(uint256(IPoolManager(POOL_MANAGER).extsload(slot))));
    }

    /// @dev The IMD value of the holding of `token` at the pool's spot price; zero without a price.
    function _value(address token, uint256 sqrtP) private view returns (uint256) {
        uint256 h = held[token];
        if (sqrtP == 0 || h == 0) return 0;
        if (IMD < token) return Math.mulDiv(Math.mulDiv(h, Q96, sqrtP), Q96, sqrtP);
        return Math.mulDiv(Math.mulDiv(h, sqrtP, Q96), sqrtP, Q96);
    }

    function _inList(Coin[] memory list, address token) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i].token == token) return true;
        }
        return false;
    }

    // ---- internals: payments ----
    /// @dev Pays a redeemer's proportional `amount` of `token` in kind under the redeem rule:
    /// `keepBps` of it is paid and the rest stays with the remaining holders.
    function _payInKind(address token, address to, uint256 amount, uint256 keepBps) private {
        uint256 paid = amount * keepBps / BPS;
        held[token] += amount - paid;
        _pay(token, to, paid);
    }

    /// @dev Pays `amount` of `token` with `PAY_GAS`; a transfer that fails, returns false or
    /// targets no code is recorded as owed instead of reverting.
    function _pay(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory ret) = token.call{gas: PAY_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
        bool success =
            ok && (ret.length == 0 ? token.code.length > 0 : (ret.length >= 32 && uint256(bytes32(ret)) == 1));
        if (success) {
            emit Paid(to, token, amount);
        } else {
            owed[to][token] += amount;
            emit Owed(to, token, amount);
        }
    }

    function _reward(address to) private {
        if (feeImd < REWARD) return;
        feeImd -= REWARD;
        IERC20(IMD).safeTransfer(to, REWARD);
        emit RewardPaid(to, REWARD);
    }

    function _lookup(uint64 launch) private view returns (address token, address hook) {
        IRegistry registry;
        if (REGISTRY_A.isRecorded(launch)) registry = REGISTRY_A;
        else if (REGISTRY_B.isRecorded(launch)) registry = REGISTRY_B;
        else revert NotRecorded(launch);
        IRegistry.Artifact[] memory artifacts = registry.artifactsOf(launch);
        for (uint256 i = 0; i < artifacts.length; ++i) {
            if (artifacts[i].role == bytes32("token") && token == address(0)) token = artifacts[i].addr;
            else if (artifacts[i].role == bytes32("hook") && hook == address(0)) hook = artifacts[i].addr;
        }
        if (token == address(0) || hook == address(0)) revert ArtifactMissing(launch);
    }
}
