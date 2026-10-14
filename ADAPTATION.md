# Corrected Imdex5 launch adaptation

The deliverable is the existing `Imdex5` application for a new Ethereum mainnet (chain id 1)
`evm_contracts` launch. It has a nonpayable, argument-free constructor that calls no other
contract. Deployment starts with zero IMDEX5 supply. The supplied build configuration and
dependencies remain unchanged: solc 0.8.26, optimizer 200 runs, via IR, Cancun, bytecode hash none.
No deployment, signing or broadcasting is performed by this work. The existing manifest is
untouched; launch handoff belongs to the subsequent manifest/deployment step.

## Changes and reasons

1. **`src/Imdex5.sol`, `_swap`:** measure the output-token balance immediately before and after
   `PoolManager.take`. Return and emit the increase, so `_mintFirst`, `_mintMore` and `_tryBuy`
   only credit actual receipts. This implements requested change 1 and fixes the reproduced
   transfer-tax accounting/last-holder finding.
2. **`src/Imdex5.sol`, `_mintMore` and mint NatSpec:** initialize `minted = shares`. For each
   nonempty holding whose buy delivers less than `need`, take the minimum with
   `Math.mulDiv(shares, out, need)` (rounding down). Reject a zero resulting amount with
   `BuyFailed(coin)`; this also rejects zero output because `need > 0` on this path. Mint and
   emit `minted`. Every executed buy and the existing fee are still paid. This implements
   requested change 2 without changing pricing, fee accounting, refund behavior or the public ABI.
   **Revision 2:** the idle IMD contribution is `Math.mulDiv(idleImd, minted, supply, Ceil)`,
   computed after the buys once `minted` is known, instead of the requested `shares`. The idle
   contribution is not a buy, so the brief's "the buyer still pays for every buy made" does not
   cover it, and charging the requested fraction for fewer shares was a systematic transfer to
   the existing holders on every mint while SwarmCity is listed (reproduced: 0.995 IMD on a
   100-share mint after a 1,000 IMD first mint with 495 IMD idle). Required by the review
   finding `a034ecce…`.
2b. **`src/Imdex5.sol`, `ask`:** when a new request opens, clear `answerHash`. An answer of the
   previous cycle that nobody submitted could otherwise be submitted, and rebalanced on, while
   the new request is open, so the index churned twice in one cycle on a week-old expired
   attestation (reproduced). The early return under 0.75 IMD of fees changes nothing, as before.
   Required by the review finding `fa8ae134…`; no new role, setting or parameter.
3. **`test/mocks/Mocks.sol` and new `test/mocks/PoolTaxERC20.sol`:** make the plain mock's
   `transfer` public/virtual to extend it, then add a mock that retains 2% of transfers whose
   sender is the PoolManager. It preserves the plain mock's storage and failure modes; index
   payments and pool settlement are untaxed. No production token or new dependency is added.
4. **`test/Imdex5.t.sol`:** retain the failed-buy assertion but replace the one-wei short-fill
   revert assertion with the expected reduced issuance, supply, receipt and balance checks.
5. **New `test/Imdex5ShortFill.t.sol`:** reproduce the audit's fourth-coin short fill; fuzz
   different shortfalls in every list position and assert the least fraction, backing for
   every holding, all buys' full cost, fees, refunds and `Minted` event. Verify zero-output
   buys, nonzero fills rounding to zero shares, and `maxImdIn` failures roll back earlier buys,
   shares, payment, fees and holdings.
6. **New `test/Imdex5TaxedCoin.t.sol`:** reproduce the first-mint overstatement and last-holder
   payout failure using the actual starting SwarmCity address. Exercise first mint, two later
   mints, a partial IMD exit, and in-kind redemption by each of three holders. Check
   `balanceOf(index) == held + sum(owed)` for every coin after each step, and independently
   bound every mint by the fraction of each holding actually added. The last holder receives
   all remaining coins; all coin balances, held, owed and idle IMD clear. Only the intentionally
   retained `feeImd` remains. Repeat this lifecycle with fuzzed amounts. Also verify net-output
   `Swapped` events, `mintFirst.minOut`, rebalance receipts, and a debt that stays backed through
   a later mint and can be claimed in full.
7. **`test/Imdex5.invariant.t.sol`:** update the mint handler's obsolete full-request issuance
   assumption to assert the delivered fraction using actual token balance changes, including
   the bound `oldHolding * minted <= received * oldSupply` for every holding. Retain all
   existing invariants, including `invariant_coinBalancesAreHeldPlusOwed`. Add an inherited suite
   running the same stateful sequences with the 2% SwarmCity mock as well as the plain suite.
8. **`README.md` and this file:** document each change, updated runtime size, actual receipt
   accounting, fractional issuance, payment consequences, audit evidence and validation.

The five initial coins and addresses, 0.50% fees, `feeImd`, `idleImd`, redeem, redeemToImd,
claim, fund, oracle question and flow, rewards, 25% rule and 2% stops retain their original
implementation. There is no owner, role, admin, setting, pause, upgrade, launch token, pool or
website added. The constructor and all other production files are unchanged.

## Imported audit findings

- **Critical — `ad6922bcd29010e53f2bd3be96444222566134e26a8429119dc4c6a01956c7d1`: reproduced.**
  Before the fix, `test_firstMintCreditsOnlyWhatArrives` observed
  `held[SC] = 19511716834983821943327` versus actual balance
  `19121482498284145504461`, exactly the reported values. Independently,
  `test_lastHolderCanReceiveEveryCoinAfterAnImdExit` observed the last holder receiving zero
  SwarmCity instead of `3921953132660064712227` units. The balance-delta fix addresses both.
- **High — `31ed5eca6a835a8650fce4020326d941263cbafa6e6dc06b1ca3c33c1a4b8bb2`: reproduced.**
  Before the fix, `test_shortFillMintsTheDeliveredFraction` reverted with
  `BuyFailed(0x54C68a4D0A21DBb1ad72FaA052db159d26F967EA)` for the fourth coin's 2% short fill.
  The fractional-issuance fix permits nonzero fills and preserves full payment for the buys.
- **Low — `3a80a3d9d6d3ec90dfdbb5d7f9e35de129d19ae1161c7bd37c0ceab25731bae3`: reproduced, with a
  citation correction.** The original 107 tests passed with the supplied seed despite the
  above failures. `test/Imdex5.t.sol` pinned the old nonzero short-fill revert; it is updated.
  The cited `test/Imdex5Revised.t.sol:40–42` actually tests a **zero-output first mint**, not a
  nonzero later-mint short fill. That case remains a required revert and is left unchanged.
  The new taxed-coin mock, lifecycle regressions and second invariant suite close the identified
  coverage gap. No application defect was dismissed as unreproducible.
- **Info — `83b7f0a5608d6208ed87e5305fc5f2a1e5b921279da2569d6311fe2baee924c1`: intentional behavior,
  confirmed by the new payment tests.** With a 2% SwarmCity tax, later mints normally issue about
  98% of requested shares, subject to integer rounding. The buyer still pays every buy, the
  idle contribution for the shares issued (revision 2) and the 0.50% buy-cost fee. Other receipts
  remain backing the index. The README explains that `maxImdIn` limits cost and
  `Minted.shares` is the actual issuance; no new minimum-share parameter is introduced.

## Independent review findings (revision 2)

Each was reproduced on the accepted tree with a scratch test before anything changed; the
answers are in `.imd-responses.json`.

- **Medium — `a034ecce04b48ed30150f0587157950fc2f790f4a640dd6037dda8b8b2041e44`: reproduced,
  fixed in part.** (a) Idle over-charge: with the taxed SwarmCity mock and 100 IMD swap caps,
  after a 1,000 IMD first mint (supply 995e18, idle 495e18) a 100-share mint issued 98e18 shares
  and charged `49748743718592964825` wei of idle IMD where the issued shares own
  `48753768844221105528`; the reported numbers exactly. Fixed by computing the idle contribution
  from `minted` (change 2, revision 2). `test_shortFillChargesIdleImdForTheSharesIssuedOnly`,
  `_mintAndCheck` in the taxed-coin suite and the invariant mint handler now assert it, and that
  the minter's pro-rata idle claim right after the mint equals its deposit to rounding.
  (b) Sliver fill: with coin 0 delivering 1e15 of 1.96e21 asked, bob paid
  `102705360721442885777` wei and received `50994999999999` wei of shares, as reported. This is
  the behaviour the brief's change 2 specifies ("the buyer still pays for every buy made") and a
  minimum-shares argument or threshold is a new safeguard the brief forbids, so it is not
  changed. The holders are never diluted (`held * minted <= received * supply` for every coin,
  asserted) and the minter is never over-issued. It is documented in the README's mint section
  so the requester accepts it knowingly, and `test_sliverFillIssuesASliverAndChargesEveryBuy`
  pins what is bounded.
- **Low — `fa8ae134b55f8950588f85d31a6c6fdb006b4c92ca62a3ac613408a9ae5ccc51`: reproduced,
  fixed.** After an answer was delivered and not submitted, a second `ask()` seven days later
  left `answerHash` in place; `submit` of the expired attestation succeeded while the new request
  was open, and `rebalance` moved the index to the stale three-coin list. Fixed by clearing
  `answerHash` when `ask` opens a request (change 2b). `test_aLaterAskReplacesAnUnsubmittedAnswer`
  now asserts the stale attestation is rejected the moment the new request opens, and
  `test_anUnsubmittedAnswerDoesNotSurviveAFailedLaterAsk` the failed-round case. Clearing at
  `ask` was preferred to an `expiresAt` check in `submit`, which would lose any answer not
  submitted within its one-day validity and leave the index waiting seven days for nothing.
- **Low — `aee12528f0bc6fdf6fba316d89c48b7a9d9a250e1a495e1fa0a1f298a548fa66`: reproduced,
  disputed (not changed).** A leftover whose pool is dead reverts every `mint` with the pool's
  error while `redeem` keeps working. This is the project's documented design: `mint` buys the
  fraction of every holding so a mint never dilutes a leftover's backing, and "a dead pool
  blocking mint (never redeem)" is accepted by the brief. Skipping the coin or paying its
  fraction another way is a new feature outside the two requested changes. The README now says
  explicitly that the acceptance covers a leftover, and that the way out is the pool working
  again and a rebalance selling it. `test_residualsAreRedeemedAndBlockMintWhileTheirPoolIsDead`
  already covers the behaviour.
- **Info — `4c473a96b373a84290409a95ac25989dc0aefef008d053e67f0549625acb11db`: reproduced,
  disputed (not changed).** Unsellable leftovers stay in `_coins` until sold, growing the loops
  by one coin each. Pre-existing in launch 1636, outside the brief, no accounting error, bounded
  by five leavers per weekly rebalance, `PAY_GAS` per coin in `redeem`. Documented in the README.

## Validation

The original code passed 107 tests. The added first-receipt, minimum-output, last-holder and
scripted-lifecycle tests failed against that code, as did the fourth-coin short-fill regression.
All tests use local mocks; no RPC, keys, environment secrets or network dependencies are needed.

Validation uses the requested seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x6bb26254590bb38e9b4480c1eb0169dec48994a727877f3f2823a28b11fb9cf1 forge test
```

Results: `forge build --sizes` passed. Imdex5 runtime is **22,662 bytes**, with **1,914 bytes**
of EIP-170 headroom; initcode is 25,237 bytes. The full seeded test run passed **123 tests**
across eight suites, with no failures or skips. This includes all eight original conservation,
fee, supply, list and oracle invariants on both plain and taxed-coin sequences. A runtime scan
using the protected check's PUSH-data skipping rule found no DELEGATECALL, CALLCODE or
SELFDESTRUCT. The ABI confirms a nonpayable constructor with no arguments.

An additional local-only `test/scratch/DeploymentCheck.t.sol` rehearses CREATE2 deployment
through a factory with zero ETH and no arguments on chain id 1, with all configured external
dependencies absent, and checks runtime size and the forbidden opcodes. It passed. Scratch scaffolding
is excluded from submission as specified by the assignment. No fork, Slither or Mythril run is
claimed; the accounting evidence comes from deterministic, fuzz and stateful Foundry tests.
