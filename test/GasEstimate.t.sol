// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

/// Wallets send a trade with the smallest gas limit that succeeds (eth_estimateGas). At that limit the trade must
/// still do all its work: play the queued turn, record its bounty and convert a due slice batch, none of them
/// silently skipped for lack of gas.
contract GasEstimateTest is Base {
    bytes32 constant CONVERTED = keccak256("Converted(address,uint256,uint256,uint256)");

    /// The smallest gas limit at which `data` sent to the router succeeds (binary search from the same state), then
    /// sends it with that limit for real and returns its logs.
    function atMinimalGas(bytes memory data) internal returns (uint256 lo, Vm.Log[] memory logs) {
        uint256 hi = 4_000_000;
        lo = 50_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(swapRouter).call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
        vm.recordLogs();
        (bool sent,) = address(swapRouter).call{gas: lo}(data);
        assertTrue(sent, "succeeds at the estimate");
        logs = vm.getRecordedLogs();
    }

    function swapCall(uint256 team, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(PoolSwapTest.swap, (pool, SwapParams(team == 1, -int256(amount),
            team == 1 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), bytes("")));
    }

    /// White in check from an unprotected queen next to its king, Kxe2 the only legal move, owned by 0xA11CE and
    /// queued; returns the trade that plays it and the currency its bounty is paid in.
    function queenTakenForAlice() internal returns (bytes memory play, Currency paidIn) {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "h1", 4);
        b = put(b, "e2", 13);
        b = put(b, "a8", 14);
        b = put(b, "a7", 9);
        hook.setPosition(id, b, side("e1"), side("a8"), 0, 0);
        white(1e18, address(0xA11CE)); // owns White's turn
        next(12);
        return (swapCall(1 - whiteTeam(), 1e17), whiteTeam() == 0 ? currency0 : currency1); // White's team's token
    }

    /// The one Reward in `logs`: its amount, from the event itself.
    function rewardAmount(Vm.Log[] memory logs) internal pure returns (uint256 amount) {
        for (uint256 i; i < logs.length; i++) if (logs[i].topics[0] == REWARD) (,,,, amount) = abi.decode(logs[i].data, (uint32, uint16, address, address, uint256));
    }

    function test_atTheEstimateTheBountyIsRecorded() public {
        (bytes memory play, Currency paidIn) = queenTakenForAlice();
        (uint256 g, Vm.Log[] memory logs) = atMinimalGas(play); // plays it
        emit log_named_uint("smallest gas limit that plays and records the bounty", g);
        assertEq(count(logs, MOVED), 1);
        assertEq(count(logs, REWARD), 1);
        assertEq(hook.owed(address(0xA11CE), paidIn.toId()), rewardAmount(logs), "recorded for the owner");
        assertGt(rewardAmount(logs), 0);
    }

    /// Whoever plays a move picks the gas limit, so no limit may let the trade go through without its bounty
    /// recorded. Every limit from far below to above the estimate, 1,000 gas apart (the estimate is measured first:
    /// --isolate adds about 100,000 to it).
    function test_noGasLimitPlaysTheMoveWithoutItsBounty() public {
        (bytes memory play, Currency paidIn) = queenTakenForAlice();
        uint256 before = vm.snapshotState();
        (uint256 estimate,) = atMinimalGas(play);
        vm.revertToState(before);
        uint256 succeeded;
        for (uint256 gas = 50_000; gas <= estimate + 20_000; gas += 1_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = address(swapRouter).call{gas: gas}(play);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (ok) {
                succeeded++;
                assertEq(count(logs, MOVED), 1, "a trade that goes through plays the move");
                assertEq(count(logs, REWARD), 1, "and records its bounty");
                assertEq(hook.owed(address(0xA11CE), paidIn.toId()), rewardAmount(logs), "recorded for the owner");
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0, "the range reaches the estimate");
    }

    function test_atTheEstimateADueBatchConverts() public {
        deployV4();
        deployMintAndApprove2Currencies();
        HookConfig memory c = config(v5(), currency0);
        c.minImd = 1e15;
        deployHook(c);
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        sampleBlocks(pool);
        // pays 10 IMD (currency0): its 0.1% slice passes the 0.001 IMD minimum, so this trade converts a batch
        (uint256 g, Vm.Log[] memory logs) = atMinimalGas(swapCall(1, 10e18));
        emit log_named_uint("smallest gas limit that converts", g);
        assertEq(count(logs, CONVERTED), 1, "the batch is not skipped");
    }
}
