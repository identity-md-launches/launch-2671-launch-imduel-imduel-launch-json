// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";

/// A bid's strength comes from its trade's share of the pool's depth (Strength.sol), and the hook has no liquidity
/// callbacks, so the depth it measures against is the smallest in-range liquidity the pool had at the start of its
/// three latest traded blocks, not the liquidity at the moment of the trade. Liquidity added just before an
/// opponent's trade and removed just after it, in the same block, then can't play that trade's move at 0%
/// (reviewer finding 9537d3ff): a bracket only counts once it has been held through the start of three traded
/// blocks, and then it shrinks every bid's share, its provider's own included.
/// Main duel at 1:1 with 1e24 of full-range liquidity: a 1% share (1e22) plays at the 90% cap.
contract JitStrengthTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

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

    /// The pool's own liquidity counts from its first traded block: the launch factory seeds the pool before anyone
    /// trades, and the first block's bids are measured against what it holds at that block's first trade.
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
