// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";

contract RefusesEth {
    bool public accepting;

    function acceptEth() external {
        accepting = true;
    }

    receive() external payable {
        require(accepting, "refused");
    }
}

/// Fees (0.4% to the chest worth less, 0.1% slice), rewards in the mover's team token from its own chest with the 2x
/// cap, failed payouts, withdrawals, chest funding and solvency. Main duel: currency0 = "IMD", currency1 = "$IMDUEL".
contract MoneyTest is Base {
    using CurrencyLibrary for Currency;

    uint256 constant TINY = 100; // a trade whose fee rounds to zero: finalizes a move without touching the chests

    function setUp() public {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    // ---------------------------------------------------------------- fees

    function test_firstTradeFundsChest0AndTheSlice() public {
        trade(1, 1e18, address(0)); // pays 1e18 of currency0 (specified): both chests empty, so chest 0 and the IMD slice
        assertEq(hook.chest(id, 0), 4e15, "0.4% of the input");
        assertEq(hook.pile(currency0.toId()), 1e15, "0.1% slice in IMD");
        assertEq(hook.chest(id, 1), 0);
        assertEq(claims(currency0), 5e15);
    }

    /// Against snipers at launch: the main duel's chest share starts 25% higher when it opens and falls to the plain
    /// 0.4% over five minutes, all of it to the chest. A duel opened later pays the plain 0.4% from its first trade,
    /// opened alongside the main duel or minutes after it.
    function test_openingSurchargeOnlyInTheMainDuel() public {
        hook.setOpening(true);
        PoolKey memory main = pool;
        uint256 opened = vm.getBlockTimestamp(); // the main duel opened in setUp
        uint24[3] memory fees = [uint24(100), 500, 1_000];
        uint256[3] memory ages = [uint256(0), 150, 300];
        uint256[3] memory bps = [uint256(2_540), 1_290, 40];
        PoolKey[] memory ks = new PoolKey[](4);
        ks[3] = main;
        uint256 before;
        for (uint256 i; i < 3; i++) {
            vm.warp(opened + ages[i]);
            vm.roll(vm.getBlockNumber() + 1);
            // the main duel at this age: its first trade fills chest 0 from currency0, so later ones go to chest 1
            // (worth less) from currency1, both taken from the input
            (pool, id) = (main, main.toId());
            (uint256 team, uint256 chestIdx) = i == 0 ? (1, 0) : (0, 1);
            before = hook.chest(id, chestIdx);
            trade(team, 1e18, address(0));
            assertEq(
                hook.chest(id, chestIdx) - before, 1e18 * bps[i] / 10_000, "the main duel's chest share at this age"
            );
            // a duel opened now: no surcharge, even in the main duel's opening minutes
            (ks[i],) = initPool(currency0, currency1, IHooks(address(hook)), fees[i], SQRT_PRICE_1_1);
            addLiquidity(ks[i]);
            (pool, id) = (ks[i], ks[i].toId());
            trade(1, 1e18, address(0));
            assertEq(hook.chest(id, 0), 4e15, "another duel pays the plain 0.4%");
        }
        assertSolvent(currency0, ks, nobody());
        assertSolvent(currency1, ks, nobody());
    }

    function test_chestShareGoesToTheChestWorthLess() public {
        trade(1, 1e18, address(0)); // chest 0 now holds more: the next chest share goes to chest 1
        uint256 before = currency1.balanceOfSelf();
        trade(1, 1e18, address(0));
        uint256 received = currency1.balanceOfSelf() - before;
        uint256 toChest1 = hook.chest(id, 1);
        assertGt(toChest1, 0);
        assertEq(toChest1, (received + toChest1) * 40 / 10_000, "0.4% of the output, in currency1");
        assertEq(hook.pile(currency0.toId()), 2e15, "the slice stays in IMD");
        assertEq(hook.chest(id, 0), 4e15, "chest 0 unchanged");
        assertSolvent(nobody());
    }

    function test_chestsStayAboutEqualInValue() public {
        for (uint256 i; i < 30; i++) {
            trade(1, 1e18, address(0)); // one-sided trading
        }
        uint256 c0 = hook.chest(id, 0);
        uint256 c1 = hook.chest(id, 1);
        assertApproxEqRel(c0, c1, 0.2e18, "within 20% at a price near 1");
        assertSolvent(nobody());
    }

    /// A trade must swap its whole order: the fee part taken before the swap counts all of it, so a trade its price
    /// limit stops early is refused rather than charged on what never traded (swarm audit 2026-10-27, finding 1). 100
    /// IMD in with the price allowed to move 0.001%: only about 10 would fill.
    function test_aTradeStoppedByItsPriceLimitIsRefused() public {
        uint256 before = currency0.balanceOfSelf();
        vm.expectRevert(); // PartialFill, wrapped by the pool manager
        swapRouter.swap(
            pool,
            SwapParams(true, -100e18, SQRT_PRICE_1_1 * 99_999 / 100_000),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(currency0.balanceOfSelf(), before, "nothing paid");
        swapRouter.swap(
            pool,
            SwapParams(true, -1e18, SQRT_PRICE_1_1 * 99_999 / 100_000),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(claims(currency0), 5e15, "a trade that fits inside its limit goes through, at 0.5%");
    }

    /// Exact output with the chest share in the output (the specified side, taken before the swap): the trader gets
    /// exactly what it asked for and the full-fill check counts the fee the pool swapped on top.
    function test_exactOutputWithTheChestShareInTheOutput() public {
        trade(1, 1e18, address(0)); // chest 0 now holds more: the next chest share goes to chest 1
        next(12);
        uint256 before = currency1.balanceOfSelf();
        swap(pool, true, 1e18, ""); // exact output of 1 currency1
        assertEq(currency1.balanceOfSelf() - before, 1e18, "exactly what was asked for");
        assertEq(hook.chest(id, 1), 4e15, "0.4% of the output, taken before the swap");
    }

    function test_exactOutputPaysTheFeeOnTheInput() public {
        uint256 inBefore = currency0.balanceOfSelf();
        uint256 outBefore = currency1.balanceOfSelf();
        swap(pool, true, 1e18, ""); // exact output of currency1: the fees fall on the unspecified input
        uint256 spent = inBefore - currency0.balanceOfSelf();
        assertEq(currency1.balanceOfSelf() - outBefore, 1e18, "the specified output is preserved");
        uint256 fee = claims(currency0);
        uint256 poolIn = spent - fee;
        assertEq(fee, poolIn * 40 / 10_000 + poolIn * 10 / 10_000, "0.4% + 0.1% of the pool's input");
        assertEq(hook.chest(id, 0) + hook.pile(currency0.toId()), fee);
    }

    // ---------------------------------------------------------------- rewards

    function fund() internal {
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
    }

    function rookTakesQueen(bool blackMoves, address owner, uint256 cap) internal {
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "e8", 14);
        if (blackMoves) {
            b = put(b, "a1", 5); // white queen
            b = put(b, "a8", 12); // black rook
        } else {
            b = put(b, "a1", 4);
            b = put(b, "a8", 13); // black queen
        }
        hook.setPosition(id, b, side("e1"), side("e8"), blackMoves ? 1 : 0, 0);
        hook.applyMove(pool, blackMoves ? mv("a8", "a1") : mv("a1", "a8"), owner, cap); // takes the queen, with check
    }

    /// The token a team is paid in: its own (0: currency0, 1: currency1).
    function teamToken(uint256 team) internal view returns (Currency) {
        return team == 0 ? currency0 : currency1;
    }

    function finalize() internal {
        next(12);
        trade(0, TINY, address(0));
    }

    /// What `who` claims in `c`: rewards are recorded, never pushed, and anyone may trigger the claim.
    function claimed(address who, Currency c) internal returns (uint256) {
        vm.prank(address(0xDEAD));
        hook.withdraw(who, c);
        return c.balanceOf(who);
    }

    function test_whiteCaptureIsPaidInItsTeamTokenFromItsOwnChest() public {
        fund();
        uint256 w = whiteTeam(); // game 0: $IMDUEL's team (currency1), the token people buy
        rookTakesQueen(false, address(0xA11CE), 1e30);
        finalize();
        assertEq(hook.owed(address(0xA11CE), teamToken(w).toId()), 3e18, "recorded for the owner to claim");
        assertEq(teamToken(w).balanceOf(address(0xA11CE)), 0, "nothing is pushed inside the trade");
        assertEq(claimed(address(0xA11CE), teamToken(w)), 3e18, "queen 2.7% + check 0.3% of a 100-token chest");
        assertEq(hook.owed(address(0xA11CE), teamToken(w).toId()), 0);
        assertEq(hook.chest(id, w), 97e18);
        assertEq(hook.chest(id, 1 - w), 100e18, "the other team's chest is untouched");
        assertSolvent(nobody());
    }

    function test_blackCaptureIsPaidInItsTeamToken() public {
        fund();
        uint256 b = 1 - whiteTeam(); // game 0: IMD's team
        rookTakesQueen(true, address(0xB0B), 1e30);
        finalize();
        assertEq(claimed(address(0xB0B), teamToken(b)), 3e18);
        assertEq(hook.chest(id, b), 97e18);
    }

    function test_payoutIsCappedAtTwiceTheTrade() public {
        fund();
        rookTakesQueen(false, address(0xA11CE), 1e18); // the move's trade received 0.5e18: cap 1e18
        finalize();
        assertEq(claimed(address(0xA11CE), teamToken(whiteTeam())), 1e18, "capped");
        assertEq(hook.chest(id, whiteTeam()), 99e18, "the rest stays in the chest");
    }

    function test_checkmatePaysAQuarterOfTheChest() public {
        fund();
        uint256 b;
        b = put(b, "g1", 6);
        b = put(b, "a1", 4);
        b = put(b, "h8", 14);
        b = put(b, "g7", 9);
        b = put(b, "h7", 9);
        hook.setPosition(id, b, side("g1"), side("h8"), 0, 0);
        uint256 w = whiteTeam(); // read before the mate starts game 1 with colours swapped
        hook.applyMove(pool, mv("a1", "a8"), address(0xA11CE), 1e30);
        finalize();
        assertEq(claimed(address(0xA11CE), teamToken(w)), 25.3e18, "mate 25% + check 0.3%");
    }

    function test_quietMovePaysNothing() public {
        fund();
        hook.applyMove(pool, mv("e2", "e4"), address(0xA11CE), 1e30);
        finalize();
        assertEq(hook.owed(address(0xA11CE), currency0.toId()) + hook.owed(address(0xA11CE), currency1.toId()), 0);
    }

    function test_bountyTable() public view {
        assertEq(hook.bountyBps(1, false, false), 30);
        assertEq(hook.bountyBps(2, false, false), 90);
        assertEq(hook.bountyBps(3, false, false), 90);
        assertEq(hook.bountyBps(4, false, false), 150);
        assertEq(hook.bountyBps(5, true, false), 300);
        assertEq(hook.bountyBps(0, true, true), 2_530);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_feesCannotBeWithdrawnByAnyone() public {
        trade(1, 1e18, address(0));
        uint256 before = claims(currency0);
        vm.prank(address(0xDEAD));
        hook.withdraw(address(0xFEE), currency0);
        assertEq(currency0.balanceOf(address(0xFEE)), 0);
        assertEq(claims(currency0), before);
        assertSolvent(nobody());
    }

    /// A reward is recorded, never sent inside the trade: an owner that can't receive it (here a contract refusing
    /// ETH) costs the trade nothing, and the owner claims it once it can.
    function test_rewardsAreClaimedNeverPushed() public {
        // a native ETH pool: White (ETH's team) is paid in ETH, to a contract that refuses ETH
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(
            pool, ModifyLiquidityParams(-887220, 887220, 100e18, 0), ""
        );
        hook.fundChest{value: 100 ether}(pool, false, 100 ether);
        address refuser = address(new RefusesEth());
        vm.recordLogs();
        rookTakesQueen(false, refuser, 1e30); // played: the reward is recorded
        next(12);
        swapNativeInput(pool, true, -int256(TINY), "", TINY); // trading goes on
        assertEq(hook.owed(refuser, 0), 3 ether, "recorded");
        assertEq(refuser.balance, 0);
        assertEq(count(vm.getRecordedLogs(), REWARD), 1);
        vm.expectRevert(); // it can't take ETH yet
        hook.withdraw(refuser, CurrencyLibrary.ADDRESS_ZERO);
        RefusesEth(payable(refuser)).acceptEth();
        vm.prank(address(0xDEAD)); // anyone may retry; only the reward owner receives it
        hook.withdraw(refuser, CurrencyLibrary.ADDRESS_ZERO);
        assertEq(refuser.balance, 3 ether);
        assertEq(hook.owed(refuser, 0), 0);
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), hook.chest(id, 0));
    }

    /// withdrawTo refuses the zero address: a token reward sent there would revert in the token, but native ETH
    /// would simply be burned by the PoolManager's transfer. The reward stays owed.
    function test_withdrawToRefusesTheZeroAddress() public {
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 1_000 ether);
        hook.fundChest{value: 100 ether}(pool, false, 100 ether);
        rookTakesQueen(false, address(this), 1e30); // White (ETH's team) is paid in ETH: 3 ether owed to this contract
        assertEq(hook.owed(address(this), 0), 3 ether, "recorded");
        uint256 held = claims(CurrencyLibrary.ADDRESS_ZERO);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.withdrawTo(CurrencyLibrary.ADDRESS_ZERO, address(0));
        assertEq(hook.owed(address(this), 0), 3 ether, "still owed");
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), held, "nothing left the hook");
        assertEq(address(0).balance, 0, "nothing burned");
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.withdrawTo(currency0, address(0)); // the token path refuses it the same way, before any transfer
        hook.withdrawTo(CurrencyLibrary.ADDRESS_ZERO, address(0xBEEF)); // a real destination works
        assertEq(address(0xBEEF).balance, 3 ether);
        assertEq(hook.owed(address(this), 0), 0);
    }

    /// A conversion batch spends at most ten minimums exactly, a pile under that whole, and a minimum too large to
    /// multiply (the suites' "never") leaves the pile whole without overflowing.
    function test_aBatchSpendsAtMostTenMinimumsExactly() public view {
        uint256 min = 10e18;
        assertEq(hook.batch(99e18, min), 99e18, "under the bound: the whole pile");
        assertEq(hook.batch(100e18, min), 100e18, "at the bound");
        assertEq(hook.batch(100e18 + 9, min), 100e18, "a few wei over: the bound, not the pile");
        assertEq(hook.batch(100e18 + 10, min), 100e18, "over: the bound");
        assertEq(hook.batch(1e30, min), 100e18, "far over: the bound");
        assertEq(hook.batch(5, NEVER), 5, "a never-minimum: the pile, no overflow");
        assertEq(hook.batch(0, min), 0);
    }

    // ---------------------------------------------------------------- funding a chest

    function test_fundChestWithTokens() public {
        hook.fundChest(pool, true, 100e18);
        assertEq(hook.chest(id, 1), 100e18);
        assertSolvent(nobody());
    }

    function test_fundChestWithEth() public {
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 10 ether);
        hook.fundChest{value: 5 ether}(pool, false, 5 ether);
        assertEq(hook.chest(id, 0), 5 ether);
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), 5 ether);
    }

    function test_fundChestNeedsTheRightValue() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest{value: 1 ether}(pool, false, 1 ether); // currency0 is a token: no ETH allowed
    }

    /// Both chests of a pool share one slot, 128 bits each: a full chest refuses funding and skips its fee share.
    function test_aFullChestTakesNoMore() public {
        uint256 full = type(uint128).max;
        MockERC20(Currency.unwrap(currency0)).mint(address(this), full);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), full);
        uint256 half = uint128(type(int128).max); // the PoolManager settles at most this much at once
        for (uint256 i; i < 2; i++) {
            hook.fundChest(pool, i == 1, half);
            hook.fundChest(pool, i == 1, half);
            hook.fundChest(pool, i == 1, 1);
        }
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest(pool, false, 1);
        trade(1, 1e18, address(0)); // chest 0 is the one worth less at 1:1, and it is full
        assertEq(hook.chest(id, 0), full);
        assertEq(hook.chest(id, 1), full);
        assertEq(hook.pile(currency0.toId()), 1e15, "the slice is still taken");
        assertEq(claims(currency0), full + 1e15);
        assertSolvent(nobody());
    }

    function test_fundChestOnlyForHookPools() public {
        PoolKey memory other = pool;
        other.fee = 500;
        other.tickSpacing = 10; // never initialized
        vm.expectRevert(IMDuelHook.NotLive.selector);
        hook.fundChest(other, false, 1e18);
    }

    // ---------------------------------------------------------------- solvency

    /// Random trading with real engine moves (captures pay out along the way): held always equals owed.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_heldEqualsOwed(uint256 seed) public {
        fund();
        address[] memory who = new address[](4);
        (who[0], who[1], who[2], who[3]) = (tx.origin, address(0xA), address(0xB), address(0xC));
        for (uint256 i; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            if ((seed >> 8) % 4 != 0) next(12 + (seed >> 16) % 40);
            address owner = (seed >> 24) % 4 == 0 ? address(0) : who[1 + (seed >> 32) % 3];
            if ((seed >> 48) % 4 == 0) swap(pool, (seed >> 40) % 2 == 0, int256(1e15 + seed % 5e18), "");
            else trade((seed >> 40) % 2, 1e15 + seed % 5e20, owner);
        }
        assertSolvent(who);
        for (uint256 i; i < who.length; i++) {
            hook.withdraw(who[i], currency0);
            hook.withdraw(who[i], currency1);
        }
        assertSolvent(who);
    }
}
