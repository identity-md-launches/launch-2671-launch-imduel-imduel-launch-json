// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";

/// A bid's strength comes from its trade's share of the pool's depth (Strength.sol): the smallest in-range liquidity
/// the pool had at the start of its three latest sampled blocks, not the liquidity at the moment of the trade. A
/// block is sampled by its first swap or its first liquidity add (beforeAddLiquidity records the liquidity before
/// the add), whichever comes first. Liquidity added just before an opponent's trade and removed just after it, in
/// the same block (reviewer finding 9537d3ff), or added, dust-traded and removed in one transaction at the start of
/// three blocks (reviewer finding 87c3e492), then can't play that trade's move at 0%: liquidity only counts once it
/// has been in the pool at the start of three sampled blocks, and then it shrinks every bid's share, its provider's
/// own included.
/// Main duel at 1:1 with 1e24 of full-range liquidity: a 1% share (1e22) plays at the 90% cap.
contract JitStrengthTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        setUpMainDuel();
    }

    function lp(int256 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(pool, ModifyLiquidityParams(-887220, 887220, liquidity, 0), "");
    }

    /// The reviewer's bracket: Alice bids at 1%; an attacker adds 1000x the pool's liquidity, Bob outbids Alice, the
    /// attacker removes it, all in one block; then the attacker bids itself. Bob's move plays as strongly as theirs.
    function test_liquidityAddedAndRemovedAroundATradeDoesNotShrinkItsShare() public {
        white(1e22, address(0xA11CE));
        uint16 alice = bid().strength;
        assertGe(alice, 8_000, "a 1% share plays near the cap");
        (uint256 before0, uint256 before1) = (currency0.balanceOf(address(this)), currency1.balanceOf(address(this)));
        lp(1e27);
        white(1.2e22, address(0xB0B)); // beats Alice's bid by 20% (White buys currency1 with currency0)
        lp(-1e27);
        assertEq(bid().owner, address(0xB0B), "Bob's bigger trade owns the move");
        uint16 bob = bid().strength;
        // the bracket cost the attacker (this contract, Bob's swapper too) nothing but Bob's swap input (rounding aside)
        int256 net0 = int256(currency0.balanceOf(address(this))) - int256(before0);
        int256 net1 = int256(currency1.balanceOf(address(this))) - int256(before1);
        assertGe(net0 + net1, -int256(1.2e22) - 2, "its liquidity came back, with Bob's LP fee");
        white(1.5e22, address(0xBAD));
        uint16 attacker = bid().strength;
        assertGe(bob, 8_000, "Bob's 1.2% share plays near the cap like Alice's");
        assertApproxEqAbs(bob, alice, 100, "the same depth as Alice's trade saw");
        assertApproxEqAbs(attacker, bob, 100, "and as the attacker's own");
    }

    /// Liquidity held across a single block boundary doesn't count either: the two earlier samples bound the depth.
    function test_liquidityHeldThroughOneBlockDoesNotShrinkTheShare() public {
        white(1e22, address(0xA11CE)); // samples 1e24 in this block
        lp(1e27); // added after this block's first trade
        next(12);
        // the first trade of the next block samples 1e27 + 1e24; it plays Alice's move and bids for White's next
        white(1.2e22, address(0xB0B));
        lp(-1e27);
        assertEq(st().moveOwner, address(0xA11CE), "Alice's move was played");
        IMDuelHook.TopBid memory bob = st().bids[whiteTeam()];
        assertEq(bob.owner, address(0xB0B));
        assertGe(bob.strength, 8_000, "the earlier block's depth still bounds the share");
    }

    /// Reviewer finding 87c3e492: three blocks each opened by one transaction [add 1e27, dust swap, remove 1e27], so
    /// the pool holds 1e27 at no block boundary and no public moment. The add is the block's first observation and
    /// records the liquidity before it, so every sample is the honest 1e24 and a victim trading later in the third
    /// block bids as the control does.
    function test_bracketsAroundABlocksFirstSwapDoNotInflateTheSample() public {
        uint256 snap = vm.snapshotState();
        white(1e22, address(0xA11CE));
        uint16 control = bid().strength;
        assertGe(control, 8_000, "control: a 1% share");
        vm.revertToState(snap);

        for (uint256 i; i < 3; i++) {
            if (i > 0) next(12);
            lp(1e27);
            black(100, address(0xBAD)); // the block's first swap, inside the bracket
            lp(-1e27);
        }
        assertEq(manager.getLiquidity(id), 1e24, "the pool holds only its honest liquidity again");
        white(1e22, address(0xA11CE));
        assertEq(bid().owner, address(0xA11CE));
        assertApproxEqAbs(bid().strength, control, 100, "measured against the 1e24 the pool started every block with");
        // and the attacker's own trade, first in the next block with no bracket, gains nothing: it plays Alice's
        // move and bids for White's next one at the same depth
        next(12);
        white(1.2e22, address(0xBAD));
        assertEq(st().moveOwner, address(0xA11CE), "Alice's move was played");
        IMDuelHook.TopBid memory attacker = st().bids[whiteTeam()];
        assertEq(attacker.owner, address(0xBAD));
        assertApproxEqAbs(attacker.strength, control, 100, "the attacker's 1.2% share plays like any other");
    }

    /// A block's first add records the liquidity before it; a swap later in the block (the same transaction or
    /// another) measures against that, whether or not the added liquidity is still there.
    function test_aBlocksFirstAddRecordsTheLiquidityBeforeIt() public {
        lp(1e27); // the block's first observation: samples 1e24
        white(1e22, address(0xA11CE)); // trades against 1e27 + 1e24
        assertGe(bid().strength, 8_000, "1% of the 1e24 the block started with");
        next(12);
        lp(1e27); // the block's first observation: samples the 1e27 + 1e24 held across the boundary
        lp(-1e27);
        white(1.2e22, address(0xB0B)); // plays Alice's move, bids for White's next
        assertEq(st().moveOwner, address(0xA11CE), "Alice's move was played");
        IMDuelHook.TopBid memory bob = st().bids[whiteTeam()];
        assertEq(bob.owner, address(0xB0B));
        assertGe(bob.strength, 8_000, "the earlier block's sample still bounds the depth");
    }

    /// Liquidity removed before a block's first sample lowers it at once and makes every bid stronger, both teams'
    /// alike: the self-harming direction the design accepts, bounded by the 90% cap.
    function test_liquidityRemovedBeforeTheFirstSampleOnlyLowersIt() public {
        lp(1e27);
        for (uint256 i; i < 3; i++) {
            next(12);
            black(100, address(0));
        }
        next(12);
        white(1e22, address(0xA11CE));
        assertLt(bid().strength, 500, "0.001% of the 1e27 held through three blocks: the curve's floor");
        next(12);
        lp(-1e27); // before this block's first swap: the swap samples 1e24
        white(1.2e22, address(0xB0B)); // plays Alice's move, bids for White's next
        assertEq(st().moveOwner, address(0xA11CE), "Alice's move was played");
        IMDuelHook.TopBid memory bob = st().bids[whiteTeam()];
        assertEq(bob.owner, address(0xB0B));
        assertGe(bob.strength, 8_000, "the smallest of the three samples is this block's 1e24");
    }

    /// Only the PoolManager may call the add callback (the launch's admission floor offers it from an outsider).
    function test_onlyThePoolManagerCallsBeforeAddLiquidity() public {
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.beforeAddLiquidity(address(this), pool, ModifyLiquidityParams(-887220, 887220, 1e18, 0), "");
    }

    /// Liquidity that stays counts: once the pool has started three traded blocks with it, a 1e22 trade is a
    /// 0.001% share of 1e27 and plays at 0%. Genuine depth changes reach the strength curve in three traded blocks.
    function test_liquidityHeldThroughThreeTradedBlocksCounts() public {
        lp(1e27);
        for (uint256 i; i < 3; i++) {
            next(12);
            black(100, address(0)); // a dust trade of the other team: samples the block, bids for nothing much
        }
        next(12);
        white(1e22, address(0xA11CE));
        assertEq(bid().owner, address(0xA11CE));
        assertLt(bid().strength, 500, "a 1e22 trade is 0.001% of 1e27: the curve's floor");
    }

    /// The pool's own liquidity counts from its first traded block: the launch factory opens the pool, seeds it and
    /// lets trading start in one block. An empty pool's add is not sampled, so the first block's bids are measured
    /// against what it holds at that block's first trade.
    function test_theFirstTradedBlockMeasuresAgainstTheLiquidityItStartsWith() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-887220, 887220, 1e24, 0), "");
        (PoolKey memory main,) = (pool, id);
        (pool, id) = (k, k.toId());
        white(1e22, address(0xA11CE));
        assertGe(bid().strength, 8_000, "1% of the liquidity the pool started the block with");
        (pool, id) = (main, main.toId());
    }

    /// The sampled depth belongs to each pool: a second duel's liquidity doesn't change the main duel's.
    function test_eachPoolSamplesItsOwnDepth() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-887220, 887220, 1e27, 0), "");
        swap(k, true, -1e22, abi.encodePacked(address(0xC)));
        assertLt(bidOf(k.toId()).strength, 500, "0.001% of the second duel");
        white(1e22, address(0xA11CE));
        assertGe(bid().strength, 8_000, "1% of the main duel");
    }
}
