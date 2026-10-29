// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookConfig} from "./Harness.sol";
import {SliceTest} from "./Slice.t.sol";

/// Conversion batches against an attacker who owns the last transaction of one block and the first of the next (hook
/// job f7f2a606's flow finding, 2026-10-29). A batch must never buy at a price pushed in an earlier transaction: its
/// reference is a price the attacker had to hold through two public blocks, and what one block can sell is capped.
contract CrossBlockTest is SliceTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    address attacker = makeAddr("attacker");

    function arm(Currency c) internal {
        MockERC20 t = MockERC20(Currency.unwrap(c));
        t.mint(attacker, 1e30);
        vm.startPrank(attacker);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// The main duel deep at 1:1, a community duel that piles ~5 IMD of slices; batches only from `minImd`, so the
    /// building trades leave it about whole (a batch there spends a few hundredths at the fair price).
    function setUpPile(uint256 minImd) internal {
        deployV4();
        (imd, duel, x) = (token("IMD"), token("IMDUEL"), token("X"));
        HookConfig memory c = config(v5(), imd);
        (c.minImd, c.minImduel) = (minImd, MIN);
        deployHook(c);
        (Currency c0, Currency c1) = sorted(imd, duel);
        (main,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(main, ModifyLiquidityParams(-887220, 887220, 10e18, 0), "");
        PoolKey memory duelX = newPool(x, imd);
        for (uint256 i; i < 5; i++) pay(duelX, imd, 1_000e18);
        arm(imd);
        arm(duel);
        next(12);
    }

    /// Trades pool `k` (hookless, or the hook's: its fee is counted either way) to just short of `target`.
    function pushPool(PoolKey memory k, bool zeroForOne, uint160 target) internal {
        (uint160 now_,,,) = manager.getSlot0(k.toId());
        uint128 l = manager.getLiquidity(k.toId());
        uint256 need = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(target, now_, l, true)
            : SqrtPriceMath.getAmount1Delta(now_, target, l, true);
        need = need * 1_000_000 / 997_000 * 1_000_000 / 995_000 * 9_999 / 10_000;
        bool ethIn = zeroForOne && k.currency0.isAddressZero();
        swapRouter.swap{value: ethIn ? need : 0}(k, SwapParams(zeroForOne, -int256(need), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false), "");
    }

    /// `amount` of currency `c` in IMD at the sqrt price `p` of a pool where `imdIs0` says which side IMD is.
    function inImd(uint256 amount, uint160 p, bool imdIs0) internal pure returns (uint256) {
        return imdIs0
            ? FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, p), 1 << 96, p)
            : FullMath.mulDiv(FullMath.mulDiv(amount, p, 1 << 96), p, 1 << 96);
    }

    /// Block N-1, last transaction: the attacker's one-spacing $IMDUEL band 20% (sqrt) past the home price in the
    /// batch's direction, and the price pushed to it. Block N, first transaction touching the main duel: convert(imd),
    /// or any dust trade there (its own batch converts). Then the band back and the price home.
    function attack(bool viaConvert, uint256 minImd) internal returns (uint256 pile0, uint256 spent, int256 profit) {
        setUpPile(minImd);
        pile0 = hook.pile(imd.toId());
        uint256 imd0 = imd.balanceOf(attacker);
        uint256 duel0 = duel.balanceOf(attacker);
        bool hookDir = imd == main.currency0; // the batch's direction: IMD in, $IMDUEL out
        (uint160 home,,,) = manager.getSlot0(main.toId());
        int24 t1 = TickMath.getTickAtSqrtPrice(uint160(uint256(home) * (hookDir ? 80 : 125) / 100)) / 60 * 60;
        ModifyLiquidityParams memory band = ModifyLiquidityParams(hookDir ? t1 - 60 : t1, hookDir ? t1 : t1 + 60, 1e22, 0);

        vm.startPrank(attacker);
        modifyLiquidityRouter.modifyLiquidity(main, band, "");
        pushTo(hookDir, TickMath.getSqrtPriceAtTick(t1));
        vm.stopPrank();
        assertGe(hook.pile(imd.toId()), pile0, "nothing converted in block N-1 (the push only adds its own slice)");
        pile0 = hook.pile(imd.toId());

        next(12);
        vm.startPrank(attacker);
        if (viaConvert) {
            hook.convert(imd);
        } else {
            swapRouter.swap(main, SwapParams(!hookDir, -int256(1e12), !hookDir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false), "");
        }
        uint256 left = hook.pile(imd.toId());
        spent = left < pile0 ? pile0 - left : 0;
        band.liquidityDelta = -1e22;
        modifyLiquidityRouter.modifyLiquidity(main, band, "");
        pushTo(!hookDir, home);
        vm.stopPrank();

        int256 dImd = int256(imd.balanceOf(attacker)) - int256(imd0);
        int256 dDuel = int256(duel.balanceOf(attacker)) - int256(duel0);
        uint256 v = inImd(_abs(dDuel), home, hookDir);
        profit = dImd + (dDuel < 0 ? -int256(v) : int256(v));
        emit log_named_uint("pile before (IMD, 1e18)", pile0);
        emit log_named_uint("IMD pile spent in block N (1e18)", spent);
        emit log_named_int("attacker profit (IMD at the home price, 1e18)", profit);
    }

    function test_crossBlockViaConvert() public {
        (uint256 pile0, uint256 spent, int256 profit) = attack(true, 4e18);
        assertLe(spent, pile0 / 100, "the pile isn't sold at a price pushed in the block before");
        assertLe(profit, 0, "the attack doesn't pay");
    }

    function test_crossBlockViaFirstTrade() public {
        (uint256 pile0, uint256 spent, int256 profit) = attack(false, 4e18);
        assertLe(spent, pile0 / 100, "the pile isn't sold at a price pushed in the block before");
        assertLe(profit, 0, "the attack doesn't pay");
    }

    // ---------------------------------------------------------------- the ETH route

}
