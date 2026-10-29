# IMDuel launch adaptation

The committed `launch.json` already describes the requested launch. No contract source, constructor argument, launch manifest, compiler setting, or dependency needed changing.

## Changes

- `test/Launch.t.sol`: fixed imported audit finding `57614ed645cd688d5926beced3ef19a3d54225bff698050e6462ceda6b95ef66`. Both the IMD launch helper (covering both token orders) and the ETH compatibility test now record logs and assert more than 20 `Moved` events across games, instead of checking only the current game's `ply`. The original trading sequences, conversion checks, and solvency assertions remain intact. This fixes the test's accounting of progress without changing chess or trading behaviour.
- `assets/imduel.svg`: added the requested token mark as a self-contained vector asset. Nine equal squares form a 3 × 3 board rotated 45 degrees; the four corners and centre are ink `#1b1715`, and the other four squares are bone `#ebe4d5`. The background is ink. A thin hollow bone frame has equal clearance on all four sides. The centred outer frame occupies approximately 60% of the image width. There are no rendered letters, pieces, gradients, shading, textures, or additional colours.
- `ADAPTATION.md`: added this change record, audit reproduction, launch compatibility notes, and validation results as required by the assignment.

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

`src/IMDuelToken.sol` has a nonpayable constructor with no arguments. It mints all 1,000,000,000 IMDUEL (18 decimals, `10^27` minor units) to its deployer, the factory, and exposes no subsequent mint or administrative capability. Neither deployed contract needs an externally linked library. Their compiled runtimes are 17,403 bytes for IMDuelHook and 1,088 bytes for IMDuelToken, below the EIP-170 limit.

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
- Full `forge test` with the seed above: **152 passed, 0 failed, 0 skipped**, across 21 suites. This includes both IMD token orders, both blank-chain admission tests with no engine code, and the existing fuzz and invariant tests.
- Compiled ABIs and artifacts: both constructors are nonpayable with the required argument shapes, no external library links, and runtime sizes below EIP-170.
- Baseline hashes: every file in `src/`, `launch.json`, and `foundry.toml` is byte-for-byte unchanged. The final diff contains only the three files listed under Changes.

The SVG was parsed and checked for its nine equal alternating cells, exact two-colour palette, rotation, symmetry, equal 34-unit clearance to the frame's inner edge, and 59.96% outer width. It needs no external assets or runtime dependency.

The pinned launch floors and security references were read alongside the local source and tests. Their verifier-owned harness imports are not present as a runnable suite in this project; the project's own admission, token, permissions, fee, bidding, withdrawal, and invariant suites supply the local checks. No mainnet fork, deployment, Slither, or Mythril run is claimed.
