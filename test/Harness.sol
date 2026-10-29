// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Rules} from "../src/Rules.sol";

/// The hook's constructor arguments in order. All static, so abi.encode(config) equals the flat arguments.
struct HookConfig {
    IPoolManager manager;
    IChessEngine engine;
    Currency imd;
    uint256 minImd;
    uint256 minImduel;
    uint256 turnBlocks;
}

/// Test-only: sets up exact positions and applies a chosen move, to test rewards and how games end.
contract IMDuelHarness is IMDuelHook {
    using PoolIdLibrary for PoolKey;

    constructor(HookConfig memory c) IMDuelHook(c.manager, c.engine, c.imd, c.minImd, c.minImduel, c.turnBlocks) {}

    /// Suites written before the opening surcharge trade right after the main duel opens and expect the plain fee;
    /// the surcharge's own tests and the invariant suites switch it on (the real hook always has it).
    bool public opening;

    function setOpening(bool on) external {
        opening = on;
    }

    function _chestBps(Game storage g) internal view override returns (uint256) {
        return opening ? super._chestBps(g) : CHEST_BPS;
    }

    function setPosition(PoolId id, uint256 board, uint32 white, uint32 black, uint16 ply, uint16 quiet) external {
        Game storage g = games[id];
        (g.board, g.whiteState, g.blackState, g.ply, g.quiet) = (board, white, black, ply, quiet);
    }

    /// Plays `move` as if a turn owned by `owner` resolved to it: recorded, and its bounty paid at once (capped at
    /// `cap`), inside an unlock as the next block's trade does.
    function applyMove(PoolKey calldata key, uint16 move, address owner, uint256 cap) external {
        manager.unlock(abi.encode(uint8(9), abi.encode(key, move, owner, cap)));
    }

    function unlockCallback(bytes calldata data) public override returns (bytes memory) {
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        if (action != 9) return super.unlockCallback(data);
        _onlyManager();
        (PoolKey memory key, uint16 move, address owner, uint256 cap) =
            abi.decode(body, (PoolKey, uint16, address, uint256));
        this.applyAndPay(key, move, owner, cap);
        return "";
    }

    function applyAndPay(PoolKey calldata key, uint16 move, address owner, uint256 cap) external {
        require(msg.sender == address(this));
        PoolId id = key.toId();
        Game storage g = games[id];
        bool black = g.ply & 1 == 1;
        (uint32 mover, uint32 other) = black ? (g.blackState, g.whiteState) : (g.whiteState, g.blackState);
        Trade memory t = Trade(1e18, cap, owner, 10_000);
        uint256 team = teamOf(g.slice, g.gameNo, black);
        _apply(id, g, move, Rules.move(g.board, mover, other, black, move), t);
        _payBounty(id, key, g, team, t);
    }

    /// The most a batch of a pile of `amount` spends at minimum `min` (_batch).
    function batch(uint256 amount, uint256 min) external pure returns (uint256) {
        return _batch(amount, min);
    }

    /// The position key held for half-move `ply`.
    function history(PoolId id, uint256 ply) external view returns (uint64) {
        (uint256 lo, uint256 hi) = _lanes(id, ply);
        return _key(lo, hi, (ply % 16) >> 1);
    }
}
