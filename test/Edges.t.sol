// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

/// Who a bid belongs to, for every hookData shape a router may pass: the address in 20 packed bytes or one 32-byte
/// ABI word (a zero address counts as none), else the wallet that signed the transaction. Anything else (wrong
/// length, a word with bits above the address) names nobody, so the signer earns.
contract OwnerShapesTest is Base {
    function setUp() public {
        setUpMainDuel();
    }

    /// White's trade in the opening block with `data`, paying `amountIn`, through the router (never the owner it
    /// earns for: the router is the hook's `sender`, the signer is tx.origin); returns the top bid's owner afterwards.
    function bidWith(bytes memory data, uint256 amountIn) internal returns (address) {
        swap(pool, whiteTeam() == 1, -int256(amountIn), data);
        return bid().owner;
    }

    function test_everyHookDataShape() public {
        address a = address(0xA11CE);
        address b = address(0xB0B);
        uint256 size = 1e15;
        assertEq(bidWith(abi.encodePacked(a), size), a, "20 bytes packed");
        assertEq(bidWith(abi.encode(b), size *= 2), b, "32 bytes ABI-encoded");
        assertEq(bidWith("", size *= 2), tx.origin, "none: the signer");
        assertEq(bidWith(abi.encodePacked(address(0)), size *= 2), tx.origin, "a packed zero address is none");
        assertEq(bidWith(abi.encode(address(0)), size *= 2), tx.origin, "an encoded zero address is none");
        assertEq(
            bidWith(abi.encode((uint256(1) << 160) | uint160(a)), size *= 2), tx.origin, "a word wider than an address"
        );
        assertEq(bidWith(abi.encode(a, uint256(1)), size *= 2), tx.origin, "64 bytes");
        assertEq(bidWith(abi.encodePacked(a, uint8(1)), size *= 2), tx.origin, "21 bytes");
        assertEq(bidWith(abi.encodePacked(bytes19(bytes20(a))), size *= 2), tx.origin, "19 bytes");
        assertEq(bidWith(abi.encodePacked(b), size *= 2), b, "a named owner takes the top bid back");
    }

    /// A bid that doesn't beat the top by more than 10% never changes its owner, whatever it names.
    function test_aBidThatDoesNotBeatTheTopKeepsItsOwner() public {
        assertEq(bidWith(abi.encodePacked(address(0xA11CE)), 1e18), address(0xA11CE));
        uint128 top = bid().size;
        assertEq(bidWith(abi.encodePacked(address(0xB0B)), 1.05e18), address(0xA11CE), "5% more is not enough");
        assertEq(bid().size, top, "the top bid is unchanged");
    }

    /// The rule as the brief states it, for any address, any 32-byte word and any other byte string.
    function testFuzz_ownerIsTheNamedAddressElseTheSigner(uint8 shape, address who, uint256 word, bytes memory raw)
        public
    {
        bytes memory data;
        address expected;
        shape %= 3;
        if (shape == 0) {
            data = abi.encodePacked(who);
            expected = who;
        } else if (shape == 1) {
            data = abi.encode(word);
            expected = word >> 160 == 0 ? address(uint160(word)) : address(0);
        } else {
            data = raw;
            if (raw.length == 20) expected = address(bytes20(raw));
            if (raw.length == 32) {
                uint256 w = uint256(bytes32(raw));
                if (w >> 160 == 0) expected = address(uint160(w));
            }
        }
        if (expected == address(0)) expected = tx.origin;
        assertEq(bidWith(data, 1e15), expected);
    }
}

/// The main duel's conversion batch at its cap: a pile of ten minimums plus one minimum's tenth or more spends
/// exactly ten minimums, and the rest waits.
contract BatchCapTest is Base {
    using CurrencyLibrary for Currency;

    bytes32 constant CONVERTED = keccak256("Converted(address,uint256,uint256,uint256)");
    uint256 constant MIN = 1e15;

    function setUp() public {
        deployV4();
        deployMintAndApprove2Currencies();
        HookConfig memory c = config(v5(), currency0); // currency0 = IMD
        (c.minImd, c.minImduel) = (MIN, MIN);
        deployHook(c);
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
    }

    /// Every batch that spent something, from the recorded logs.
    function batches(Vm.Log[] memory logs) internal view returns (uint256 n, uint256 spent) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != CONVERTED) continue;
            (uint256 s,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            if (s != 0) (n, spent) = (n + 1, spent + s);
        }
    }

    function test_aPileJustOverTheCapSpendsTenMinimums() public {
        vm.recordLogs();
        trade(1, 10_010e15, address(0)); // pays IMD: a slice of 0.1%, 10.01e15 = ten minimums and a hundredth
        assertEq(hook.pile(currency0.toId()), 10 * MIN + MIN / 100);
        sampleBlocks(pool); // the third sampled block's trade runs the first batch
        next(12);
        trade(1, 100, address(0)); // the pile left is under one minimum: no batch starts by itself
        (uint256 n, uint256 spent) = batches(vm.getRecordedLogs());
        assertEq(n, 1, "one batch");
        assertEq(spent, 10 * MIN, "capped at ten minimums");
        assertEq(hook.pile(currency0.toId()), MIN / 100, "the rest waits");
        hook.convert(currency0); // anyone may still run it in a later block
        next(12);
        hook.convert(currency0);
        assertEq(hook.pile(currency0.toId()), 0, "a small pile goes whole");
        assertEq(
            claims(currency0),
            hook.chest(id, 0) + hook.pile(currency0.toId()) + hook.owed(tx.origin, currency0.toId()),
            "IMD held = owed"
        );
    }

    /// Below the minimum a pile waits for trades; convert() still runs it on request once three blocks are sampled.
    function test_aPileUnderOneMinimumOnlyConvertsOnRequest() public {
        trade(1, 900e15, address(0)); // a 0.9e15 slice: under one minimum
        sampleBlocks(pool);
        next(12);
        trade(1, 100, address(0));
        assertEq(hook.pile(currency0.toId()), 900e12, "trades leave it");
        hook.convert(currency0);
        assertEq(hook.pile(currency0.toId()), 0, "convert() takes it");
    }

    /// Before three blocks are sampled nothing is bought, however big the pile.
    function test_nothingConvertsBeforeThreeSampledBlocks() public {
        trade(1, 100_000e15, address(0));
        uint256 pile = hook.pile(currency0.toId());
        hook.convert(currency0);
        next(12);
        hook.convert(currency0);
        assertEq(hook.pile(currency0.toId()), pile, "two sampled blocks: no batch");
    }
}

/// previewMove at the edges of a three-block window: nothing before the window's last block or without a bid.
contract PreviewEdgesTest is Base {
    function turnBlocks() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public {
        setUpMainDuel();
    }

    function test_noPreviewBeforeTheLastBlockOrWithoutABid() public {
        (bool ready,) = hook.previewMove(id, keccak256("h"));
        assertFalse(ready, "no bid");
        next(12);
        next(12); // the window's last block, still without a bid
        (ready,) = hook.previewMove(id, keccak256("h"));
        assertFalse(ready, "no bid in the last block either");
        white(1e18, address(0xA11CE));
        (ready,) = hook.previewMove(id, keccak256("h"));
        assertTrue(ready, "a bid in the last block: ready, given the hash");
    }

    function test_aBidEarlyInTheWindowIsNotPreviewedUntilItsLastBlock() public {
        white(1e18, address(0xA11CE));
        (bool ready,) = hook.previewMove(id, keccak256("h"));
        assertFalse(ready, "first block of three");
        next(12);
        (ready,) = hook.previewMove(id, keccak256("h"));
        assertFalse(ready, "second block of three");
        next(12);
        (ready,) = hook.previewMove(id, keccak256("h"));
        assertTrue(ready, "the last block");
    }
}
