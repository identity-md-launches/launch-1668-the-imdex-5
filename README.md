# IMDEX5 — The Imdex 5

An index of the five largest tokens paired with IMD on Ethereum mainnet (chain id 1), as one
contract, `Imdex5` (`src/Imdex5.sol`). The contract's own ERC-20 is the share: name
`The Imdex 5`, symbol `IMDEX5`, 18 decimals, plain transfers, supply 0 at deployment and no cap.
A mint issues shares, a redeem burns them, nothing else mints. Anyone can call everything; there
is no owner, admin, role, setting, pause or upgrade.

Contracts only: no launch token, pool or website.

## Layout

| Path | What |
| --- | --- |
| `src/Imdex5.sol` | The index. One contract, no constructor arguments, 22,662 bytes of runtime. |
| `src/OracleAttestation.sol` | The protocol's `OracleAttestation` library and `OracleAttestationConsumer`, copied whole from the oracle-consumer reference. |
| `src/Interfaces.sol` | The slices of the Uniswap v4 `PoolManager`, the launch registries and the Intake that the index calls. |
| `test/Imdex5.t.sol` | Behaviour, failure and attack tests against mocks. |
| `test/OracleConsumerConformance.t.sol` | The protocol's digest and selector vectors. |
| `test/mocks/Mocks.sol` | Mock ERC-20 (can revert, return false or burn gas), a constant-product stand-in for the PoolManager (price limits, partial fills, short fills, the nonzero-delta count), registries, Intake, an ERC-1271 signer and a hook that re-enters, burns gas or leaves a delta unsettled. |
| `lib/` | OpenZeppelin Contracts 5.6.1 and forge-std 1.9.6, vendored as ordinary files. |

Build and test:

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins solc 0.8.26, optimizer 200 runs, `via_ir`, `cancun`, `bytecode_hash = "none"`.
Tests mock every outside contract by etching mocks at the mainnet addresses the contract hard-codes;
there are no fork tests and no environment reads.

## Deployment parameters

The constructor takes no arguments, calls no contract and checks no code length. Everything about
the chain is a constant:

| Constant | Value |
| --- | --- |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Registry A | `0xA47FcB220DDd1cDddA865F89029BEc1b9EcA3bf1` |
| Registry B | `0x7c9D5ee697BfF5Ac4F10E2E54d3f40c44e48fE23` |
| Intake (version 2) | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` |
| Action | `bytes32("oracle.request@oracle-1")` |
| Oracle signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Pool key | IMD and the coin sorted, fee 12500, tick spacing 60, hooks = the launch's hook |
| EIP-712 domain | name `IdentityMD Oracle`, version `2`, this chain, this contract |

### Starting list

The constructor seeds the list below. On 2026-10-13 both registries were read through a public
RPC: each launch is recorded in exactly one registry, and every `token` and `hook` artifact equals
the brief's value, so nothing differs and nothing was substituted.

| Launch | Symbol | Token | Hook | Registry |
| --- | --- | --- | --- | --- |
| 1282 | INFER | `0x53d0eA0A685220718Dc6a0a6e4617194C6F37921` | `0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000` | B |
| 1283 | MARG | `0xfA0EfEa559bdE229031c2B0A219472316647759c` | `0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc` | A |
| 737 | ZTO | `0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e` | `0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000` | B |
| 1075 | SCAT | `0x54C68a4D0A21DBb1ad72FaA052db159d26F967EA` | `0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000` | B |
| 1175 | SC | `0x1ae93A4D9CC0b41C594D00387B6F832a88f729b7` | `0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000` | B |

### Numbers the brief left open (named constants)

| Constant | Value | Why |
| --- | --- | --- |
| `SQRT_UP_BPS` / `SQRT_DOWN_BPS` | 10100 / 9900 | A limited swap's sqrt-price limit is the spot sqrt price moved 1%, which is a price move of about 2% (2.01% up, 1.99% down). |
| `WEIGHT_DIVISOR` | 4 | The 25% weight cap. |
| `MAX_LIST` | 5 | The most launch numbers an answer may carry. |
| `MIN_AGREED` | 4 | The panel agreement `onOracleResult` requires. |
| `SWAP_GAS` | 1,000,000 | Gas given to each skippable swap (`swapSelf` from `rebalance` and `redeemToImd`). A hook that burns everything it is given costs at most this much per swap, so the rest of the call still runs. A swap that needs more is skipped (or, in `redeemToImd`, paid in kind). |
| `PAY_GAS` | 300,000 | Gas given to each coin transfer in `redeem` and the in-kind part of `redeemToImd`. A coin that burns it all becomes owed instead of starving the next payment. |

## How it works

### Accounting

Internal accounting, with swap receipts measured using the output token's `balanceOf` before
and after the PoolManager's `take`:

- `held[coin]`: units of each coin the index owns for its holders.
- `idleImd`: IMD a rebalance left unspent. The holders'.
- `feeImd`: fees. Outside every mint, redeem and rebalance; it only ever pays the oracle price
  (0.5 IMD) and caller rewards (0.25 IMD). `fund(amount)` lets anyone add to it.

After accounted operations, the IMD the contract holds equals `idleImd + feeImd` plus any IMD
recorded as `owed`. Each coin's balance equals `held[coin]` plus the amounts recorded as `owed`.
The invariant suites check these equalities with both plain coins and a SwarmCity mock that keeps
2% of transfers out of the PoolManager. `held` increases only by what actually arrives, and
`Swapped.amountOut` reports that receipt, including for rebalance buys.

### Mint

- `mintFirst(imdIn, minOut[])`: only at supply 0. 0.50% of `imdIn` goes to `feeImd`; the rest
  buys each coin of the list with an equal IMD part and mints one share per IMD of the rest.
  The IMD the swaps did not consume (the division's remainder, and whatever a pool whose
  liquidity ran out could not take, which v4 reports in the swap's delta) goes to `idleImd`, so
  every IMD the contract holds is accounted for. Reverts if a buy reverts, returns nothing (a
  dust input the pool fee swallows whole is a failed buy, not a share for nothing) or returns
  under its `minOut`. `minOut` has one entry per coin of the list, in list order.
- `mint(shares, maxImdIn)`: supply > 0. Pulls `maxImdIn` first, requests exactly `held * f` of every
  coin (`f = shares / totalSupply`, rounded up), adds 0.50% of the buys' cost to `feeImd`, mints,
  and refunds the unspent IMD. Starts with `minted = shares`; for each short fill, reduces it to
  the smaller of its current value and `floor(shares * received / need)`. Then adds
  `idleImd * minted / totalSupply` (rounded up) to `idleImd`: the idle contribution follows the
  shares issued, not the shares asked for, so a short fill never charges idle IMD the new shares
  do not own. It issues and emits `minted`. Reverts if the total exceeds
  `maxImdIn`, if the total is zero (a share is never issued for nothing), if a buy reverts or
  delivers nothing, or if the resulting shares round to zero. No price is read; no cap.
  A list coin whose holding is zero (its
  buy was skipped at the last rebalance) is not bought by `mint`, exactly as `held * f` says;
  the next `rebalance` buys it from idle IMD.

While SwarmCity is held, its 2% transfer tax normally means about 98% of the requested later-mint
shares are issued (subject to integer rounding). The buyer still pays for every buy made, the
idle IMD contribution for the shares issued, and the 0.50% fee on the buys' cost. Other coins
bought in excess of the issued fraction remain backing the index for its holders.
`maxImdIn` limits the payment; it is not a minimum-share guarantee. Read `Minted.shares` for the
amount actually issued. The first mint's share calculation remains IMD paid less its 0.50% fee;
its coin receipts and `minOut` checks use the amounts actually received.

There is no minimum-shares floor, by the brief ("no new safeguard"). A buy that delivers only a
sliver of one coin, because that pool's liquidity is one-sided, bounded or was withdrawn just
before the mint, issues only that sliver's fraction of the requested shares while the exact-output
buys of the other coins are still paid in full; the excess stays with the existing holders. A
minter who cannot tolerate that should mint in a private transaction or check the pools' depth
first. `maxImdIn` caps the payment but a short fill lowers the total, so it does not refuse one.

### Redeem

- `redeem(shares)`: burns, then pays 99.50% of `held * f` of each coin and of `idleImd * f`
  (100% when the supply reaches 0; the 0.50% stays with the remaining holders). No price, no
  trade. Each transfer gets `PAY_GAS`; one that reverts, returns false, runs out of that gas or
  targets an address without code is recorded in `owed[caller][coin]` instead of blocking;
  `claim(coin)` takes it later and can only pay once.
- `redeemToImd(shares, minImdOut)`: same burn and `f`; sells `held * f` of each coin inside the
  PoolManager's `unlock`, adds `idleImd * f`, keeps 0.50% as `feeImd`, pays the rest in IMD and
  reverts under `minImdOut`. A coin whose sale reverts (or fills short) is paid in kind under
  the same rule as `redeem`: 99.50% of the unsold part, the rest staying with the remaining
  holders, and all of it when the supply reaches zero. Both redeem paths therefore pay the same
  amount of a coin that cannot be sold.

### Oracle

- `ask()`: anyone, when no request is open, no list awaits a rebalance, and 7 days have passed
  since the last ask. With under 0.75 IMD of `feeImd` it returns without doing anything.
  Otherwise it pays the Intake 0.5 IMD through `requestWithFailure` and the caller 0.25 IMD.
- The body is built on chain by `body()`: `v` 1, the question, chain 1, window 24 hours, answer
  type `bytes32[]`, evidence `panel`, panel 5, quorum 4, `validForSeconds` 86400, `head` 5 and
  `consumer {chainId: 1, verifyingContract: this}`.
- `onOracleResult`: only from the Intake, only for the open request, only with `agreed >= 4`:
  stores `keccak256(answer)` and closes the request. Every other case returns. It moves no
  tokens and runs well under 200,000 gas (tested with a 200,000 gas call).
- `onOracleFailure`: only from the Intake, for the open request: closes it. `closeRequest()`
  lets anyone close a request open for 2 days.
- `submit(attestation, signature)`: anyone. `keccak256(answer)` must equal the stored hash and
  the signature must verify for the signer over this contract's EIP-712 digest (ECDSA, or
  ERC-1271 if the signer has code, through OpenZeppelin's `SignatureChecker`). Decodes 1 to 5
  distinct launch numbers (distinct tokens too), reads each token and hook from the registry that
  records it, reverts if either is missing, stores them as the next list and pays the caller
  0.25 IMD from `feeImd` if it can.

### Rebalance

`rebalance()`: anyone, when a next list is stored. Inside one `unlock`:

1. Sells every coin not in the next list into `idleImd`, each sale limited to a 2% price move.
2. Adopts the list. A leaver that step 1 could not fully sell (its pool is dead, or the 2% limit
   stopped the sale) stays in the holdings after the list, so it is still redeemed and minted
   proportionally and sold again by the next rebalance.
3. With four or more coins in the list, sells any holding above 25% of total value down to 25%,
   by pool spot prices read at the start of this step (`extsload` of the pool's `slot0`).
4. Spends `idleImd` on the list in equal parts; a buy stops at 25% weight or a 2% price move.

A swap that reverts is skipped (each swap is its own external self-call, `swapSelf`, so a revert
undoes only that swap). The skip holds against a hook the launch chose that misbehaves only for
the index: `swapSelf` is given `SWAP_GAS`, so a hook that burns all its gas costs one bounded
swap, and after settling, `swapSelf` reads the manager's transient nonzero-delta count
(`exttload` of Uniswap v4's `NonzeroDeltaCount` slot) and reverts if a hook left a delta of
its own unsettled, which the manager would otherwise only reject at the end of `unlock`,
undoing the whole rebalance. The caller gets 0.25 IMD from `feeImd` if it can pay.

`ask()` may be called again 7 days after the last ask even when an answer was delivered but
nobody submitted it; opening the new request clears the old answer's hash, so the week-old
attestation can no longer be submitted (it would otherwise rebalance the index twice in one
cycle: once on the stale list while the new request is open, once on the new one). This is
deliberate: an answer whose `submit` can never succeed (a launch number no registry records, a
missing artifact) must not block the oracle loop forever, and the cost is bounded to the normal
weekly 0.75 IMD. If the new request fails or times out, no answer is left; the loop waits for the
next interval as after any failed round.

## Security notes

- Every state-changing function is `nonReentrant` and emits an event. `unlockCallback` accepts
  only the PoolManager and only while one of the index's own operations holds the guard;
  `swapSelf` accepts only the contract itself. A hook or coin that re-enters hits the guard.
- IMD is pulled only from `msg.sender`; the PoolManager is paid with `transfer` from the index's
  own balance, never `transferFrom` with another payer.
- Shares are minted only against IMD actually paid: `mint` rounds every proportional amount up,
  charges the swaps' real cost plus fee and refuses a mint that would cost nothing;
  `mintFirst` refuses a buy that returns nothing and keeps the IMD the swaps did not consume
  as the holders' idle IMD, so the index can never reach a supply with nothing behind it.
- Redeem reads no price, makes no swap and cannot be blocked by a coin: failures become `owed`,
  each transfer is capped at `PAY_GAS` so a coin that burns gas cannot starve the next one, and
  `claim` zeroes the debt before paying.
- `feeImd` leaves only to the Intake (0.5 IMD) and as 0.25 IMD rewards.
- A forged callback (wrong sender, wrong request id, thin agreement) is ignored; a forged
  attestation fails the signature; a tampered field changes the digest.

Accepted, by the brief: thin-pool price impact, a pool's own hook fee, a dead pool blocking mint
(never redeem), a short fill that issues fewer shares than asked (above), and an oracle that
never answers. A hook that burns gas or leaves a delta unsettled for the index's swaps makes that
swap a skipped one in `rebalance` and an in-kind payment in `redeemToImd`; in `mint` and
`mintFirst` it is a failed buy, which reverts, as a dead pool does. That includes a leftover: a
coin that left the list but could not be sold stays in the holdings so it is still redeemed, and
`mint` buys its fraction like any other holding, so while its pool is dead every `mint` reverts
until the pool works again and a rebalance sells it; `redeem` and `redeemToImd` keep working. Such
leftovers also stay in the holdings until sold, so each unsellable leaver adds one coin to the
redeem, mint and rebalance loops; at the list's size (five coins, at most five leavers per
weekly rebalance) the cost grows slowly and `redeem` has `PAY_GAS` per coin, never more.
`submit` checks only the stored hash and the signature, as the brief asks, not the attestation's
`expiresAt`: the hash already binds the answer to the index's own request, and the hash is
cleared once a list is stored or a new request opens, so an attestation is taken once and only
for the cycle that produced it.

Gas to supply: `rebalance` needs at most `SWAP_GAS` per swap it attempts (up to 5 sales of
leavers, one trim per holding and one buy per list coin) plus a few hundred thousand; `redeem`
needs `PAY_GAS` per coin plus overhead. Under that, a hostile hook or coin can still exhaust the
call, which then simply reverts and can be retried with more gas.

Tests passing is not an audit. Work holding other people's funds needs an independent
adversarial review before release.

## Operational responsibilities

Nothing is owned. After launch:

- Someone must `fund` at least 0.75 IMD of `feeImd` before the first `ask` can pay; mint and
  redeemToImd fees top it up afterwards.
- Someone must call `ask()` (weekly at most), `submit` the signed attestation the Intake
  delivered (it is in the `Answered` event's request and the oracle's receipt), and `rebalance()`.
  Each of the three pays its caller 0.25 IMD when `feeImd` can.
- If the oracle never calls back, anyone may `closeRequest()` after 2 days.
- The launch deploys `Imdex5` from its bytecode as built, with no arguments. No `launch.json` is
  written here; the manifest step writes it.

## Changes for the corrected launch

Every change from the supplied launch 1636 project is listed here; audit reproduction and
validation details are in `ADAPTATION.md`.

| File | Change and reason |
| --- | --- |
| `src/Imdex5.sol` | `_swap` measures the balance increase around `take`, returning and emitting the actual receipt so transfer tax cannot inflate holdings. `_mintMore` issues the least delivered fraction of requested shares, rejects zero output/zero resulting shares, and emits the actual shares while charging all buys and fees; its idle IMD contribution is `idleImd * minted / supply` (rounded up), computed after the buys, so a short fill is not charged the requested fraction of idle IMD for fewer shares (review finding, revision 2). `ask()` clears `answerHash` when it opens a new request, so an unsubmitted answer of the previous cycle cannot be submitted and rebalanced on while the new request is open (review finding, revision 2). The mint NatSpec describes this behavior. |
| `test/mocks/Mocks.sol` | Makes the mock's `transfer` public and virtual so the taxed mock can reuse its balances and failure modes. Plain-token behavior is unchanged. |
| `test/mocks/PoolTaxERC20.sol` | Adds a mock that keeps 2% of transfers from the PoolManager; transfers from the index remain untaxed. |
| `test/Imdex5.t.sol` | Replaces the obsolete nonzero short-fill revert expectation with fractional issuance and balance assertions; retains the failed-buy revert check. |
| `test/Imdex5ShortFill.t.sol` | Adds deterministic and fuzz tests for short fills, the least fill across all coins, full payment and refunds, zero output, zero rounded shares, payment limits and atomic rollback. Revision 2: the idle contribution of a short fill equals the issued shares' fraction and the minter's pro-rata idle claim equals its deposit to rounding; a sliver fill issues a sliver, pays every buy and dilutes nobody. |
| `test/Imdex5TaxedCoin.t.sol` | Adds the first receipt and last-holder regressions, the complete three-holder lifecycle with two later mints and an IMD exit, fuzzed lifecycles, actual-output events and minimums, rebalance buys, and funded owed/claim coverage. Each lifecycle step checks balances against held plus owed; each mint checks backing against every holding and, since revision 2, that idle IMD is charged for the shares issued. |
| `test/Imdex5.invariant.t.sol` | Checks minted shares against actual receipts and proportional backing (and, since revision 2, the idle contribution against the shares issued); runs the existing invariants both with plain tokens and with the taxed SwarmCity mock. The held-plus-owed invariant is retained. |
| `test/Imdex5Edges.t.sol` | Revision 2: a later ask drops the unsubmitted answer at once, so the stale attestation is rejected while the new request is open and after the new request fails. |
| `README.md` | Updates the measured runtime size, corrects accounting and mint descriptions, documents the short-fill payment consequence and lists this change set. |
| `ADAPTATION.md` | Records the changes, imported findings, reproductions, unchanged launch requirements and local validation. |
