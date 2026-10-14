// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IIntake, IPoolManager, IRegistry, IUnlockCallback} from "../../src/Interfaces.sol";

/// @dev A plain ERC-20 whose transfers can be made to revert, return false or burn all gas.
contract MockERC20 {
    uint8 public failMode; // 0 ok, 1 revert, 2 return false, 3 burn every gas given
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setFailMode(uint8 mode) external {
        failMode = mode;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        if (failMode == 1) revert("transfer disabled");
        if (failMode == 2) return false;
        if (failMode == 3) _burnGas();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _burnGas() private pure {
        assembly {
            invalid()
        }
    }
}

interface IMockHook {
    function beforeSwap(address sender) external;
}

bytes32 constant NONZERO_DELTA_COUNT_SLOT = 0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;

/// @dev A constant-product stand-in for Uniswap v4's PoolManager: unlock, swap with exact input
/// or output and a sqrt price limit, sync/settle/take deltas, `extsload` of slot0 and `exttload`
/// of the nonzero-delta count. `maxIn` caps what a pool can take in one exact-input swap (its
/// liquidity runs out, as v4 reports with a partial delta); `shortBy` makes a swap pay that much
/// less than it should.
contract MockPoolManager {
    struct Pool {
        uint256 r0;
        uint256 r1;
        bool exists;
        bool dead;
        uint256 shortBy;
        uint256 maxIn;
    }

    uint256 private constant Q96 = 2 ** 96;

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => bytes32) public slotToPool;
    mapping(address => int256) public delta;
    address[] private touched;
    address private syncedCurrency;
    uint256 private syncedBalance;
    bool public unlocked;

    function poolId(IPoolManager.PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function setPool(IPoolManager.PoolKey memory key, uint256 r0, uint256 r1) external {
        bytes32 id = poolId(key);
        pools[id] = Pool(r0, r1, true, false, 0, 0);
        slotToPool[keccak256(abi.encode(id, uint256(6)))] = id;
    }

    function setDead(IPoolManager.PoolKey memory key, bool dead) external {
        pools[poolId(key)].dead = dead;
    }

    function setShortBy(IPoolManager.PoolKey memory key, uint256 shortBy) external {
        pools[poolId(key)].shortBy = shortBy;
    }

    function setMaxIn(IPoolManager.PoolKey memory key, uint256 maxIn) external {
        pools[poolId(key)].maxIn = maxIn;
    }

    function exttload(bytes32 slot) external view returns (bytes32) {
        if (slot != NONZERO_DELTA_COUNT_SLOT) return bytes32(0);
        uint256 count;
        for (uint256 i = 0; i < touched.length; ++i) {
            if (delta[touched[i]] != 0) count += 1;
        }
        return bytes32(count);
    }

    function sqrtPriceOf(IPoolManager.PoolKey memory key) public view returns (uint256) {
        Pool memory p = pools[poolId(key)];
        if (!p.exists) return 0;
        return Math.sqrt(Math.mulDiv(p.r1, Q96 * Q96, p.r0));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        bytes32 id = slotToPool[slot];
        Pool memory p = pools[id];
        if (!p.exists) return bytes32(0);
        return bytes32(Math.sqrt(Math.mulDiv(p.r1, Q96 * Q96, p.r0)));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "AlreadyUnlocked");
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i = 0; i < touched.length; ++i) {
            require(delta[touched[i]] == 0, "CurrencyNotSettled");
        }
        delete touched;
        unlocked = false;
    }

    function swap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        returns (int256)
    {
        require(unlocked, "ManagerLocked");
        bytes32 id = poolId(key);
        Pool storage p = pools[id];
        require(p.exists, "PoolNotInitialized");
        require(!p.dead, "dead pool");
        if (key.hooks.code.length > 0) IMockHook(key.hooks).beforeSwap(msg.sender);
        uint256 sqrtK = Math.sqrt(p.r0 * p.r1);
        uint256 current = sqrtPriceOf(key);
        uint256 maxIn;
        uint256 rIn;
        uint256 rOut;
        if (params.zeroForOne) {
            require(params.sqrtPriceLimitX96 < current, "PriceLimitAlreadyExceeded");
            (rIn, rOut) = (p.r0, p.r1);
            uint256 bound = Math.mulDiv(sqrtK, Q96, params.sqrtPriceLimitX96);
            maxIn = bound > rIn ? bound - rIn : 0;
        } else {
            require(params.sqrtPriceLimitX96 > current, "PriceLimitAlreadyExceeded");
            (rIn, rOut) = (p.r1, p.r0);
            uint256 bound = Math.mulDiv(sqrtK, params.sqrtPriceLimitX96, Q96);
            maxIn = bound > rIn ? bound - rIn : 0;
        }
        if (p.maxIn != 0 && p.maxIn < maxIn) maxIn = p.maxIn;
        uint256 amountIn;
        uint256 amountOut;
        if (params.amountSpecified < 0) {
            amountIn = uint256(-params.amountSpecified);
            if (amountIn > maxIn) amountIn = maxIn;
            amountOut = Math.mulDiv(rOut, amountIn, rIn + amountIn);
            amountOut = amountOut > p.shortBy ? amountOut - p.shortBy : 0;
        } else {
            uint256 desired = uint256(params.amountSpecified);
            require(desired < rOut, "insufficient liquidity");
            amountIn = Math.mulDiv(rIn, desired, rOut - desired, Math.Rounding.Ceil);
            if (amountIn > maxIn) {
                amountIn = maxIn;
                amountOut = Math.mulDiv(rOut, amountIn, rIn + amountIn);
            } else {
                amountOut = desired;
            }
            if (amountOut > p.shortBy) amountOut -= p.shortBy;
        }
        address inCur = params.zeroForOne ? key.currency0 : key.currency1;
        address outCur = params.zeroForOne ? key.currency1 : key.currency0;
        if (params.zeroForOne) {
            p.r0 += amountIn;
            p.r1 -= amountOut;
        } else {
            p.r1 += amountIn;
            p.r0 -= amountOut;
        }
        _touch(inCur);
        _touch(outCur);
        delta[inCur] -= int256(amountIn);
        delta[outCur] += int256(amountOut);
        int256 a0 = params.zeroForOne ? -int256(amountIn) : int256(amountOut);
        int256 a1 = params.zeroForOne ? int256(amountOut) : -int256(amountIn);
        return int256((uint256(a0) << 128) | uint256(uint128(int128(a1))));
    }

    function sync(address currency) external {
        syncedCurrency = currency;
        syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(syncedCurrency).balanceOf(address(this)) - syncedBalance;
        _touch(syncedCurrency);
        delta[syncedCurrency] += int256(paid);
    }

    function take(address currency, address to, uint256 amount) external {
        _touch(currency);
        delta[currency] -= int256(amount);
        require(IERC20(currency).transfer(to, amount), "take failed");
    }

    function _touch(address currency) private {
        for (uint256 i = 0; i < touched.length; ++i) {
            if (touched[i] == currency) return;
        }
        touched.push(currency);
    }
}

/// @dev A hook that, when armed, tries to re-enter the index during a swap and records the result,
/// or misbehaves for one swap sender only: takes IMD from the manager and never settles it
/// (`MISBEHAVE_TAKE`), or burns every gas it is given (`MISBEHAVE_BURN`).
contract ReentrantHook is IMockHook {
    uint8 public constant MISBEHAVE_TAKE = 1;
    uint8 public constant MISBEHAVE_BURN = 2;

    address public target;
    bytes public payload;
    bool public armed;
    uint256 public attempts;
    bool public reentered;
    uint8 public misbehave;
    address public victim;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function setMisbehave(uint8 mode, address victim_) external {
        misbehave = mode;
        victim = victim_;
    }

    function beforeSwap(address sender) external {
        if (misbehave != 0 && sender == victim) {
            attempts += 1;
            if (misbehave == MISBEHAVE_TAKE) {
                IPoolManager(msg.sender).take(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, address(this), 1);
            } else {
                assembly {
                    invalid()
                }
            }
            return;
        }
        if (!armed) return;
        attempts += 1;
        // slither-disable-next-line low-level-calls
        (bool ok,) = target.call(payload);
        if (ok) reentered = true;
    }
}

contract MockRegistry is IRegistry {
    mapping(uint64 => bool) public recorded;
    mapping(uint64 => Artifact[]) private artifacts;

    function record(uint64 launch, address token, address hook) external {
        recorded[launch] = true;
        delete artifacts[launch];
        artifacts[launch].push(Artifact(bytes32("distributor"), bytes32("MerkleDistributor"), address(0xd15)));
        if (token != address(0)) artifacts[launch].push(Artifact(bytes32("token"), bytes32("Token"), token));
        if (hook != address(0)) artifacts[launch].push(Artifact(bytes32("hook"), bytes32("Hook"), hook));
    }

    function isRecorded(uint64 launch) external view returns (bool) {
        return recorded[launch];
    }

    function artifactsOf(uint64 launch) external view returns (Artifact[] memory) {
        return artifacts[launch];
    }
}

contract MockIntake is IIntake {
    uint256 public count;
    bytes32 public lastRequestId;
    bytes32 public lastAction;
    bytes public lastBody;
    Callback public lastCallback;
    bytes4 public lastOnFailure;
    uint256 public lastAmount;

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        count += 1;
        requestId = keccak256(abi.encode("request", count));
        lastRequestId = requestId;
        lastAction = action;
        lastBody = body;
        lastCallback = callback;
        lastOnFailure = onFailure;
        lastAmount = amount;
    }
}

/// @dev Etched at the oracle signer's address in tests: an ERC-1271 wallet that accepts the
/// signatures of one test key, so the index's constant signer can be exercised without its key.
contract MockSigner {
    address private immutable KEY;

    constructor(address key) {
        KEY = key;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered,,) = ECDSA.tryRecover(hash, signature);
        return recovered == KEY ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
