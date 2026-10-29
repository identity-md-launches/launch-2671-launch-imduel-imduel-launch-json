# IMDuel launch adaptation

The committed `launch.json` already describes the requested launch. No constructor argument, launch manifest, compiler setting, or dependency needed changing. The first round changed only tests and the logo. The revision round (below) changed `src/IMDuelHook.sol` where a reviewer's reproduced finding required it: the hook's behaviour, interface, constructor shape and permissions are otherwise unchanged.

## Revision round: reviewer findings

Each finding was reproduced before anything was changed. The reviewer's proof test for the first one failed on the starting tree (Bob at 271 bps) and passes on this one.

- **9537d3ff (medium, fixed): JIT liquidity collapses an opponent's bid strength.** `beforeSwap` read the pool's in-range liquidity at the moment of the trade, and the hook has no liquidity callbacks, so liquidity added in the transaction before an opponent's trade and removed in the one after shrank that trade's share to nothing at no cost. The fix, in `src/IMDuelHook.sol`, keeps the permissions in `launch.json` unchanged: a bid's strength is now measured against the smallest in-range liquidity the pool had at the start of its three latest traded blocks (`_sampleDepth`, one storage slot per pool, packed like the main duel's price samples). The sample is written by the first swap of each block, before any swap of that block has changed the liquidity, so a bracket in one block does not count; liquidity has to be in the pool at the start of three traded blocks, held through two public ones where anyone can trade against it, and then it shrinks every bid's share, its provider's own included. Liquidity removed for a block raises every bid's strength, both teams' alike, bounded by the 90% cap; that is the trade-off, documented in the code. The first traded block of a pool measures against what the pool holds at its first trade, so the factory-seeded launch pool works from its first block. Tests: `test/JitStrength.t.sol` (the reviewer's bracket, a bracket held across one block, liquidity held through three traded blocks counting, a pool's first block, per-pool samples). The hook's runtime grew from 17,403 to 17,628 bytes, within the 23,500-byte budget `test/Size.t.sol` holds it to; `test/HookGas.t.sol`'s budgets still pass.
- **c1752b40 (low, fixed): `withdrawTo` accepted `address(0)`.** Reproduced by reading the path: a native-ETH reward sent to the zero address is a plain value call that succeeds, so the reward is burned, where a token reward reverts in the token. `withdrawTo` now reverts with `BadValue` for a zero destination before touching the owed balance. Test: `test_withdrawToRefusesTheZeroAddress` in `test/Money.t.sol` (ETH duel, 3 ether owed, the call reverts, the balance stays owed and nothing leaves the hook; a real destination still works).
- **8c23f3ef (info, fixed): a batch could spend up to nine wei over its ten-minimum bound.** Reproduced by arithmetic. `_batch` now returns exactly `BATCH_MINS * min` for any pile over it, with the division check kept first so a minimum too large to multiply (the test suites' "never") returns the pile without overflowing. Test: `test_aBatchSpendsAtMostTenMinimumsExactly` in `test/Money.t.sol`, through a `batch` accessor added to `test/Harness.sol`.
- **68825ec7 (info, fixed): the constructor accepted a zero minimum.** Reproduced by reading `_batch`: with `min = 0` every batch spends nothing, so the slice never converts. The constructor now rejects `minImd == 0` or `minImduel == 0` with `BadConfig`, beside its engine and `turnBlocks` checks. The launch passes 10 IMD and 1,000,000 IMDUEL, so the committed arguments are unaffected. Tests: `test_rejectsBadConfig` in `test/Game.t.sol` gained both cases; `test/Size.t.sol` encoded a stale argument shape whose fourth and fifth words were zero and now passes the launch's six arguments.
- **64cb1176 (info, documentation fixed): the burn is a transfer inside a trade.** Reproduced: the slice batch's burn of IMDUEL to `0x…dEaD` runs during the trader's unlock. The safety goal holds (IMDUEL has no transfer callbacks, the dead address has no code, the batch runs in a try/catch), so no code changed; the contract notes now say that no *reward* is ever sent inside a trade and name the burn as the one transfer. `launch.json`'s notes carry the older wording and are the manifest step's to update.

## Changes

- `test/Launch.t.sol`: fixed imported audit finding `57614ed645cd688d5926beced3ef19a3d54225bff698050e6462ceda6b95ef66`. Both the IMD launch helper (covering both token orders) and the ETH compatibility test now record logs and assert more than 20 `Moved` events across games, instead of checking only the current game's `ply`. The original trading sequences, conversion checks, and solvency assertions remain intact. This fixes the test's accounting of progress without changing chess or trading behaviour.
- `assets/imduel.svg`: added the requested token mark as a self-contained vector asset. Nine equal squares form a 3 × 3 board rotated 45 degrees; the four corners and centre are ink `#1b1715`, and the other four squares are bone `#ebe4d5`. The background is ink. A thin hollow bone frame has equal clearance on all four sides. The centred outer frame occupies approximately 60% of the image width. There are no rendered letters, pieces, gradients, shading, textures, or additional colours.
- `ADAPTATION.md`: added this change record, audit reproduction, launch compatibility notes, and validation results as required by the assignment.
- Revision round, `src/IMDuelHook.sol`: the sampled bid depth (`depths`, `_sampleDepth`, used by `beforeSwap`), the zero-address check in `withdrawTo`, the exact `_batch` bound, the zero-minimum check in the constructor, and the corrected contract notes; see the section above for the finding each answers.
- Revision round, tests: `test/JitStrength.t.sol` (new), `test/Money.t.sol`, `test/Game.t.sol`, `test/Harness.sol`, `test/Size.t.sol`, as listed above.

## Audit reproduction

With Forge 1.8.3, the existing project configuration, and the supplied fuzz seed, the original `forge test --match-path test/Launch.t.sol` produced two passes and one failure: `test_launchPairedWithEth`, with `assertion failed: 8 <= 20`.

The verbose trace showed `GameOver(gameNo: 0, result: 1, plies: 23)` followed by `GameStarted(gameNo: 1)`. The hook correctly resets the new game's half-move counter, so checking that counter discarded the preceding game's moves. Counting emitted moves preserves the intended progress check across checkmates and draws. The same assumption existed in the IMD helper and was corrected there too. The existing ETH scenario supplies the regression case across a game boundary; both IMD address orders exercise the other corrected assertion.

The single supplied finding reproduced and was fixed. There were no supplied findings that failed to reproduce.

## Launch compatibility and preserved decisions

The hook's nonpayable constructor takes exactly `(address,address,address,uint256,uint256,uint256)`, matching these six committed values in order:

1. `$poolManager`, supplied by the factory.
2. ChessEngineV5 at `0xc21788f704a8b9456f7391a01d8a3d95be215a27`.
3. IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`.
4. `10000000000000000000` (10 IMD).
5. `1000000000000000000000000` (1,000,000 IMDUEL).
6. `3` blocks per bidding window.

The engine address is already resolved in `launch.json`; no replacement or additional engine deployment is required. Construction does not call the engine or require its code. `launch/hook.json` is an existing template: its hook, token, and pool fields agree with the committed manifest after resolving its `ENGINE_ADDRESS` field to the address above.

`src/IMDuelToken.sol` has a nonpayable constructor with no arguments. It mints all 1,000,000,000 IMDUEL (18 decimals, `10^27` minor units) to its deployer, the factory, and exposes no subsequent mint or administrative capability. Neither deployed contract needs an externally linked library. Their compiled runtimes are 17,628 bytes for IMDuelHook (17,403 before the revision round) and 1,088 bytes for IMDuelToken, below the EIP-170 limit.

The launch pool remains IMDUEL/IMD at fee 12500 and tick spacing 60. Permissions remain exactly `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. Enabled callbacks require the PoolManager. There are no liquidity callbacks to obstruct the factory's fee collection, and no owner, administrator, pause, upgrade path, or backend signer.

The existing economics remain unchanged: 0.4% to the pool's reward chests and a 0.1% protocol slice; the main duel's initial chest share starts at 25.4% and falls to 0.4% over 300 seconds, without imposing that surcharge on later duels. Protocol slices route through IMD or IMDUEL into the main duel, with the existing conversion bounds and reward/burn split. The committed launch introduces no native ETH conversion route. The existing ETH-paired compatibility fixture remains a test of a different constructor configuration, not a change to this launch.

Move rewards remain owed balances claimed through `withdraw` or `withdrawTo`; a trade never pays a reward recipient. Bid ownership remains the nonzero address in 20-byte packed or 32-byte ABI-encoded `hookData`, otherwise `tx.origin`. A relayed smart-contract-wallet trade without that data credits the relayer; this is the accepted limitation, and no router allowlist or signer was added.

## Validation

All Foundry checks use the project's existing configuration. Test runs use:

```sh
FOUNDRY_FUZZ_SEED=0x2eccb05281127f36e24130aa34904997669251c54c425513f1bc27bfec195d10 forge test
```

Results with Forge 1.8.3:

- `forge build`: passed, with existing compiler/lint warnings.
- `forge test --match-path test/Launch.t.sol`: all three launch scenarios passed after the correction.
- Full `forge test` with the seed above, first round: **152 passed, 0 failed, 0 skipped**, across 21 suites. After the revision round: **160 passed, 0 failed, 0 skipped** across 22 suites (plus the reviewer's proof, copied under `test/scratch/`, which passes), including both IMD token orders, both blank-chain admission tests with no engine code, and the existing fuzz and invariant tests.
- Compiled ABIs and artifacts: both constructors are nonpayable with the required argument shapes, no external library links, and runtime sizes below EIP-170.
- Baseline hashes: `launch.json`, `foundry.toml`, every other file in `src/` and every dependency are byte-for-byte unchanged. After the revision round the diff against the accepted tree is `src/IMDuelHook.sol`, the five test files listed under Changes, and this file.

The SVG was parsed and checked for its nine equal alternating cells, exact two-colour palette, rotation, symmetry, equal 34-unit clearance to the frame's inner edge, and 59.96% outer width. It needs no external assets or runtime dependency.

The pinned launch floors and security references were read alongside the local source and tests. Their verifier-owned harness imports are not present as a runnable suite in this project; the project's own admission, token, permissions, fee, bidding, withdrawal, and invariant suites supply the local checks. No mainnet fork, deployment, Slither, or Mythril run is claimed.
