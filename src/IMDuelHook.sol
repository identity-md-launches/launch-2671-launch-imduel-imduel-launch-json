// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Chess} from "./Chess.sol";
import {Strength} from "./Strength.sol";
import {Rules} from "./Rules.sol";
import {IChessEngine} from "./IChessEngine.sol";

// The hook's permission bits; its address must carry them.
uint160 constant IMDUEL_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// IMDuel: chess played by your trades. One open hook that works the same in every pool: each pool plays an
/// endless series of games between its two tokens. Buying a token plays for its team; the teams swap colours every
/// game. Every buy bids for its team's next move, at a strength set by its share of the pool; the biggest owns the
/// move, and a new top bid must beat the old one by more than 10%. A move stays open for `turnBlocks` blocks after the
/// previous one was played; the first trade after that plays it, with the hash of the window's last block as the dice,
/// so a bidder can't know the move while it can still bid. The one exception is whoever builds that last block: it can
/// bid in it and try several versions of it, keeping the hash whose move pays (an accepted risk; a move pays at most
/// twice what its trade received). Its owner's reward is recorded then, in its team's token from its team's war
/// chest, and the owner claims it (withdraw): nothing is ever sent inside a trade, so no recipient runs code while a
/// trader's PoolManager is unlocked. The owner is the address the trade names in hookData, else the wallet that
/// signed the transaction, so a trade through any router earns.
/// Money: 0.5% of every swap. 0.4% goes to the pool's chest worth less; 0.1% (the protocol slice) is converted into
/// $IMDUEL in batches, half added to the main duel's $IMDUEL chest and half burned. So every duel pairs a token with
/// IMD or $IMDUEL: one with no route to $IMDUEL can't open. A trade must swap its whole order: the fee part taken
/// before the swap counts all of it.
/// It implements only the callbacks its permission bits enable; the pool manager calls no others.
contract IMDuelHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- rules of play
    uint256 public constant TURN_TIMEOUT = 600; // seconds without a move before the side to move plays at 0%
    uint256 public constant RAISE_PCT = 10; // a new top bid pays more than this much over the current one
    uint16 public constant MAX_PLY = Chess.MAX_PLY;
    uint16 public constant MAX_QUIET_PLY = Chess.MAX_QUIET_PLY;
    // the engine's heaviest measured move is ~950k (test/EngineV5Games.t.sol); 3x that bounds what a pathological
    // position can cost: a trade with less gas than the cap needs reverts (NotEnoughGas), one with more gets the fallback
    uint256 internal constant ENGINE_GAS = 3_000_000;
    uint256 internal constant FALLBACK_GAS = 2_000_000;
    // EIP-2935: the last 8,191 block hashes (about a day), beyond the 256 the BLOCKHASH opcode serves
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    // ---------------------------------------------------------------- money
    uint256 public constant CHEST_BPS = 40;
    // against snipers at launch: for OPENING seconds after the main duel opens its chest share starts OPENING_BPS higher
    // and falls to normal; the extra goes to the chest like the rest (time only: nothing counts wallets). Other duels
    // never pay it
    uint256 public constant OPENING = 300;
    uint256 public constant OPENING_BPS = 2_500;
    uint256 public constant SLICE_BPS = 10;
    // a move pays at most twice its trade's output from the pool (for exact output, the chest share included)
    uint256 public constant PAYOUT_CAP = 2;
    /// Bounties by piece type (1 pawn, 2 bishop, 3 knight, 4 rook, 5 queen), 16 bits each: chess values at 0.3%.
    uint256 internal constant PIECE_BPS = (30 << 16) | (90 << 32) | (90 << 48) | (150 << 64) | (270 << 80);
    uint256 public constant CHECK_BPS = 30;
    uint256 public constant MATE_BPS = 2_500;
    uint256 internal constant CONVERT_GAS = 800_000;
    uint256 internal constant BATCH_SQRT_BPS = 10; // a conversion batch stops 0.1% of the sqrt price away (~0.2%)
    uint256 internal constant BATCH_MINS = 10; // a batch spends at most 10 minimums (_batch), one per block
    uint256 internal constant SAMPLE_BITS = 56; // a sampled sqrt price: 8-bit exponent, 48-bit mantissa (_pack)
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable manager;
    IChessEngine public immutable engine; // chooses each move and plays it by the rules (Rules.sol)
    Currency public immutable imd;
    uint256 internal immutable minImd; // smallest pile worth a conversion batch, per routing currency
    uint256 internal immutable minImduel;
    uint256 public immutable turnBlocks; // how many blocks a move stays open for bids once the previous one is played

    struct Game {
        bool live; // pool initialized with this hook
        uint8 slice; // which currency (0 or 1) the protocol slice is taken in
        uint32 gameNo; // the team of the token people buy (not the slice side) plays White in even games
        uint16 ply; // half-moves played in this game; odd = Black to move
        uint16 quiet; // half-moves since the last capture or pawn move
        uint32 whiteState;
        uint32 blackState;
        uint32 turnStart; // when the side to move got the turn
        uint40 closeBlock; // the last block the side to move's move can be bid for in: the dice are its hash
        bool main; // the main duel
        uint32 opened; // when the main duel opened (its opening surcharge runs for OPENING seconds); 0 in other duels
        // each team's top bid for its next move (by team: 0 currency0's, 1 currency1's); the side to move's is the
        // move being bid for now. Played bids keep their fields (a flag, not zeroes, so the next bid rewrites warm
        // storage)
        TopBid[2] bids;
        // the last move played
        uint16 movePly;
        uint32 moveGameNo;
        address moveOwner;
        uint16 moveStrength;
        uint8 moveCaptured; // piece type taken, 0 none
        bool moveCheck;
        bool moveBlack;
        uint8 moveResult; // game result if the move ended the game: 1 white, 2 black, 3 draw
        uint256 board;
    }

    /// A team's top bid for its next move: owner 0 and size 0 for a timeout move.
    struct TopBid {
        address owner;
        uint16 strength;
        bool open; // a bid is waiting for its move
        uint128 size; // what it paid, in the other team's token
        uint128 cap; // the most its move can pay, in its team's token
    }

    /// A bid for a turn (all zero for a timeout turn).
    struct Trade {
        uint256 size; // what it paid, in the other team's token
        uint256 cap; // the most the move can pay, in the team's token
        address owner;
        uint16 strength;
    }

    mapping(PoolId => Game) internal games; // read through game(id)
    // The last 16 final positions as 64-bit keys, four to a slot: lane (ply % 16) holds the position after that
    // half-move, even lanes in slots 0-1 and odd lanes in slots 2-3, so each side's eight are two reads.
    // Provisional or replaced positions never enter this ring.
    mapping(PoolId => uint256[4]) internal recentPositions;
    // war chests per pool: currency0's team in the low 128 bits, currency1's team in the high 128 (read: chest)
    mapping(PoolId => uint256) internal chests;
    // The main duel, $IMDUEL / IMD: the first pool opened on this hook. The IMD launch factory deploys the hook, mints
    // $IMDUEL and opens this pool in one transaction, so $IMDUEL's address isn't known at construction.
    Currency public imduel;
    uint24 internal mainFee;
    int24 internal mainSpacing;
    PoolId public mainId;
    // The main duel's price samples, one slot (_sample): the block of the latest batch (40 bits), the block of the
    // latest sample (40), and the price at the start of the three latest sampled blocks (56 each, newest lowest).
    // A batch buys within 0.1% (sqrt) of the most hook-favourable of the three, so a price pushed inside a block, or
    // at the end of the block before, can't sell the hook $IMDUEL dear: it must be held through two public blocks.
    // Every trade and batch of the main duel samples it before moving its price.
    uint256 internal samples;
    mapping(uint256 => uint256) public pile; // protocol slices waiting for conversion, by currency id
    mapping(address => mapping(uint256 => uint256)) public owed; // rewards to claim (withdraw), by currency id

    event GameStarted(PoolId indexed pool, uint32 gameNo);
    event Moved(
        PoolId indexed pool,
        uint32 gameNo,
        uint16 ply,
        uint16 move,
        address owner,
        uint256 size,
        uint16 strengthBps,
        uint8 captured, // piece type taken (1 pawn .. 5 queen), 0 none
        bool check
    );
    event Bid(PoolId indexed pool, uint32 gameNo, uint16 ply, address owner, uint256 size, uint16 strengthBps); // the top bid for half-move `ply` so far
    event GameOver(PoolId indexed pool, uint32 gameNo, uint8 result, uint16 plies); // 1 white, 2 black, 3 draw
    event DrawTriggered(PoolId indexed pool, uint32 gameNo, uint8 reason, uint16 plies); // 1 stalemate, 2 material, 3 repetition, 4 quiet, 5 cap
    event EngineFailed(PoolId indexed pool, uint32 gameNo, uint16 ply);
    event Reward(PoolId indexed pool, uint32 gameNo, uint16 ply, address owner, Currency currency, uint256 amount); // recorded for the owner to claim
    event Withdrawn(address indexed who, Currency currency, uint256 amount);
    event ChestFunded(PoolId indexed pool, address indexed from, Currency currency, uint256 amount);
    event Converted(Currency indexed from, uint256 spent, uint256 bought, uint256 burned);
    event MainDuel(PoolId indexed pool, Currency imduel);

    error NotManager();
    error NotSelf();
    error NotLive();
    error BadValue();
    error BadConfig();
    error NotEnoughGas(); // the engine ran out of gas: send the trade with more
    error NoRoute(); // a duel pairs IMD or $IMDUEL, so its slice converts into $IMDUEL
    error PartialFill(); // the trade's price limit stopped it before its whole order traded

    /// Plain arguments, as the IMD launch factory passes them (launch.json): the PoolManager, the engine, IMD (the
    /// currency the main duel pairs with; native ETH for an ETH-paired launch), the smallest pile worth a conversion
    /// batch in IMD and in $IMDUEL (a batch spends at most BATCH_MINS of it), and how many blocks a move stays open
    /// for bids (3 on Ethereum, about 36 seconds; at least 1).
    constructor(IPoolManager manager_, IChessEngine engine_, Currency imd_, uint256 minImd_, uint256 minImduel_,
        uint256 turnBlocks_)
    {
        // the engine is not checked here: the launch's admission tests build the hook on a chain where it has no code
        // (hook job f7f2a606); its address is checked off chain, and a trade with no engine to answer just waits
        if (address(engine_) == address(0) || turnBlocks_ == 0 || turnBlocks_ > 1_000) revert BadConfig();
        turnBlocks = turnBlocks_;
        (manager, engine, imd) = (manager_, engine_, imd_);
        (minImd, minImduel) = (minImd_, minImduel_);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------- views

    /// The callbacks this hook uses, which its address carries (v4's BaseHook convention: the IMD launch reads it).
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        (p.afterInitialize, p.beforeSwap, p.afterSwap, p.beforeSwapReturnDelta, p.afterSwapReturnDelta) =
            (true, true, true, true, true);
    }

    function game(PoolId id) external view returns (Game memory) {
        return games[id];
    }

    /// The war chest of a pool's team `i` (0: currency0's, 1: currency1's), in balance claims.
    function chest(PoolId id, uint256 i) public view returns (uint256) {
        return i == 0 ? uint128(chests[id]) : chests[id] >> 128;
    }

    /// The share of a team chest a move pays (basis points), before the 2x cap.
    function bountyBps(uint8 captured, bool check, bool mate) public pure returns (uint256 bps) {
        bps = (PIECE_BPS >> (uint256(captured) << 4)) & 0xffff;
        if (check) bps += CHECK_BPS;
        if (mate) bps += MATE_BPS;
    }

    /// The team (0: currency0's, 1: currency1's) playing a side in a game. In game 0 White is the team of the token
    /// people buy, the side the slice isn't taken in (the main duel: $IMDUEL, so buyers move first at launch, when
    /// the pool holds no IMD to sell for); colours alternate every game.
    function teamOf(uint8 slice, uint32 gameNo, bool black) internal pure returns (uint256) {
        return (gameNo & 1) ^ (black ? 1 : 0) ^ (slice ^ 1);
    }

    // ---------------------------------------------------------------- hook callbacks

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external returns (bytes4) {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        g.live = true;
        (Currency c0, Currency c1) = (key.currency0, key.currency1);
        if (imduel.isAddressZero()) {
            // the first pool is the main duel: it must pair IMD with a token, $IMDUEL (else the opening reverts)
            Currency token = c0 == imd ? c1 : c0;
            if (!(c0 == imd || c1 == imd) || token.isAddressZero()) revert BadConfig();
            (imduel, mainFee, mainSpacing, mainId) = (token, key.fee, key.tickSpacing, id);
            (g.main, g.opened) = (true, uint32(block.timestamp));
            emit MainDuel(id, token);
        }
        // every duel's slice buys $IMDUEL: one side must be IMD or $IMDUEL
        if (!(c0 == imd || c1 == imd || c0 == imduel || c1 == imduel)) revert NoRoute();
        // the slice is taken in the side it converts from most simply: IMD, then $IMDUEL
        g.slice = c1 == imd ? 1 : c0 == imd ? 0 : c1 == imduel ? 1 : 0;
        _newGame(id, g);
        return IHooks.afterInitialize.selector;
    }

    /// Reads the pool once for the whole swap (chest values, strength) and takes the parts of the fee due in the
    /// specified currency. The rest is taken in afterSwap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        (uint160 sqrtPrice,,,) = manager.getSlot0(id);
        if (g.main) _sample(sqrtPrice);
        uint256 depth = manager.getLiquidity(id); // sets a bid's strength: every buy bids
        uint256 chestIdx = _smallerChest(id, sqrtPrice);
        int256 a = params.amountSpecified;
        int128 taken = _takeFee(id, key, _specified(params), uint256(a < 0 ? -a : a), chestIdx, g);
        _stash(sqrtPrice, depth, chestIdx, taken);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(taken, 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        returns (bytes4, int128)
    {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        (uint160 sqrtPrice, uint256 liquidity, uint256 chestIdx, int128 taken) = _unstash();
        uint256 specIdx = _specified(params);
        // the whole order, less the fee taken before the swap, must have traded: that fee counted all of it, so a trade
        // its price limit stopped early would pay it on what never traded (up to 25.4% in the main duel's opening)
        if (int256(specIdx == 0 ? delta.amount0() : delta.amount1()) != params.amountSpecified + taken) revert PartialFill();
        uint256 unspecIdx = 1 - specIdx;
        int128 fee = _takeFee(id, key, unspecIdx, _abs(unspecIdx == 0 ? delta.amount0() : delta.amount1()), chestIdx, g);
        if (!_locked()) {
            _lock(true);
            _play(id, key, g, params.zeroForOne, delta, hookData, sqrtPrice, liquidity);
            _lock(false);
        }
        return (IHooks.afterSwap.selector, fee);
    }

    // ---------------------------------------------------------------- fees and chests

    /// Takes the chest share and the slice that fall in currency `idx` of a trade side of `amount`, as balance claims.
    function _takeFee(PoolId id, PoolKey calldata key, uint256 idx, uint256 amount, uint256 chestIdx, Game storage g)
        internal
        returns (int128)
    {
        uint256 toChest = chestIdx == idx ? _addChest(id, idx, amount * _chestBps(g) / 10_000) : 0;
        uint256 toPile = g.slice == idx ? amount * SLICE_BPS / 10_000 : 0;
        uint256 fee = toChest + toPile;
        if (fee == 0) return 0;
        Currency c = idx == 0 ? key.currency0 : key.currency1;
        manager.mint(address(this), c.toId(), fee);
        if (toPile != 0) pile[c.toId()] += toPile;
        return int128(int256(fee));
    }

    /// The chest share in basis points: CHEST_BPS, plus, in the main duel only, the opening surcharge falling from
    /// OPENING_BPS to nothing over its first OPENING seconds.
    function _chestBps(Game storage g) internal view virtual returns (uint256) {
        uint256 age = block.timestamp - g.opened;
        return !g.main || age >= OPENING ? CHEST_BPS : CHEST_BPS + OPENING_BPS * (OPENING - age) / OPENING;
    }

    /// The chest worth less at the pool's price (0 or 1), so the fee keeps both chests about equal.
    function _smallerChest(PoolId id, uint160 sqrtPrice) internal view returns (uint256) {
        uint256 both = chests[id];
        uint256 value0 = FullMath.mulDiv(FullMath.mulDiv(uint128(both), sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
        return value0 <= both >> 128 ? 0 : 1;
    }

    /// Adds up to `amount` to chest `i` and returns what fit: a chest holds at most 2^128 - 1 (a token with more
    /// than ~3.4e20 whole tokens of supply), past that the chest share is simply not taken.
    function _addChest(PoolId id, uint256 i, uint256 amount) internal returns (uint256) {
        uint256 both = chests[id];
        uint256 have = i == 0 ? uint128(both) : both >> 128;
        uint256 room = type(uint128).max - have;
        if (amount > room) amount = room;
        if (amount != 0) chests[id] = both + (i == 0 ? amount : amount << 128);
        return amount;
    }

    function _takeChest(PoolId id, uint256 i, uint256 amount) internal {
        chests[id] -= i == 0 ? amount : amount << 128;
    }

    /// Records team `team`'s reward in its token for `to` to claim. Nothing is sent inside the trade: a recipient
    /// would run code while the trader's PoolManager is unlocked (ETH's receive, a token's transfer callback) and
    /// could make that trade, and every later one playing the same move, revert.
    function _pay(PoolId id, Game storage g, PoolKey calldata key, uint256 team, address to, uint256 amount) internal {
        Currency c = team == 0 ? key.currency0 : key.currency1;
        owed[to][c.toId()] += amount;
        emit Reward(id, g.moveGameNo, g.movePly, to, c, amount);
    }

    function _send(Currency c, address to, uint256 amount) internal {
        manager.burn(address(this), c.toId(), amount);
        manager.take(c, to, amount);
    }

    /// Sends `who` their rewards in `c`. Anyone can call it; the tokens only ever go to `who`.
    function withdraw(address who, Currency c) external {
        _withdraw(who, c, who);
    }

    /// The same for the caller's own rewards, sent to `to`: for an owner that can't receive them itself (a contract
    /// without receive(), an address the token blocks).
    function withdrawTo(Currency c, address to) external {
        _withdraw(msg.sender, c, to);
    }

    function _withdraw(address who, Currency c, address to) internal {
        uint256 amount = owed[who][c.toId()];
        if (amount == 0) return;
        owed[who][c.toId()] = 0;
        manager.unlock(abi.encode(uint8(0), abi.encode(to, c, amount)));
        emit Withdrawn(who, c, amount);
    }

    /// Adds to a team's war chest. Anyone can; the chest records what actually arrived. For native ETH send exactly
    /// `amount` as value; for tokens approve the hook first.
    function fundChest(PoolKey calldata key, bool inCurrency1, uint256 amount) external payable {
        PoolId id = key.toId();
        if (!games[id].live) revert NotLive();
        Currency c = inCurrency1 ? key.currency1 : key.currency0;
        if (msg.value != (c.isAddressZero() ? amount : 0)) revert BadValue();
        uint256 paid = abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(msg.sender, c, amount))), (uint256));
        if (_addChest(id, inCurrency1 ? 1 : 0, paid) != paid) revert BadValue(); // the chest is full
        emit ChestFunded(id, msg.sender, c, paid);
    }

    /// Converts one batch of the protocol slice held in `c` now (it also happens by itself inside trades).
    function convert(Currency c) external {
        manager.unlock(abi.encode(uint8(2), abi.encode(address(0), c, uint256(0))));
    }

    function unlockCallback(bytes calldata data) public virtual returns (bytes memory) {
        _onlyManager();
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        (address who, Currency c, uint256 amount) = abi.decode(body, (address, Currency, uint256));
        if (action == 0) {
            _send(c, who, amount);
            return "";
        }
        if (action == 2) {
            _convert(c);
            return "";
        }
        manager.sync(c);
        uint256 paid;
        if (c.isAddressZero()) {
            paid = manager.settle{value: amount}();
        } else {
            // the return value is not read (some tokens return nothing): settle() credits what actually arrived
            (bool ok,) = Currency.unwrap(c).call(abi.encodeCall(IERC20Min.transferFrom, (who, address(manager), amount)));
            if (!ok) revert BadValue();
            paid = manager.settle();
        }
        manager.mint(address(this), c.toId(), paid);
        return abi.encode(paid);
    }

    // ---------------------------------------------------------------- the protocol slice

    function convertBatch(Currency c) external {
        _onlySelf();
        _convert(c);
    }

    /// One batch of the pile in `c` into $IMDUEL, with balance claims only: IMD buys $IMDUEL in the main duel, up to
    /// a price limit (_swapClaims); what isn't spent stays in the pile. Half the $IMDUEL goes to the main duel's
    /// $IMDUEL chest, half is burned. The hook's own swaps skip its callbacks: they play no move and pay no fee.
    function _convert(Currency c) internal {
        uint256 id = c.toId();
        uint256 amount = pile[id];
        if (amount == 0) return;
        uint256 spent = amount;
        uint256 bought = amount;
        if (c == imd) {
            (spent, bought) = _swapClaims(_mainKey(), imd, _batch(amount, minImd));
        } else if (!(c == imduel)) {
            return; // no slice is taken in it (every duel pairs IMD or $IMDUEL), so there is nothing to convert
        }
        pile[id] = amount - spent;
        uint256 kept = _addChest(mainId, imduel < imd ? 0 : 1, bought - bought / 2);
        uint256 burned = bought - kept; // half, or more if the chest is full
        if (burned != 0) _send(imduel, DEAD, burned);
        emit Converted(c, spent, bought, burned);
    }

    /// The most a batch of a pile of `amount` spends: BATCH_MINS minimums (`min`), or the pile.
    function _batch(uint256 amount, uint256 min) internal pure returns (uint256) {
        return amount / BATCH_MINS > min ? BATCH_MINS * min : amount;
    }

    /// Swaps `amountIn` of `input` in the main duel (`key`) up to the batch price limit, paying and receiving as
    /// balance claims. The limit is 0.1% (sqrt) past the pool's reference price (_reference: the limit is a band, and
    /// an attacker could fill a band past a price it pushed with its own liquidity). Nothing is bought once the price
    /// is past the limit, while fewer than three blocks are sampled, or when a batch already swapped this block (one
    /// per block: a pushed price must not sell the pile batch after batch).
    function _swapClaims(PoolKey memory key, Currency input, uint256 amountIn)
        internal
        returns (uint256 spent, uint256 got)
    {
        bool zeroForOne = input == key.currency0;
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint256 s = _sample(sqrtPrice);
        uint256 from = _reference(s, zeroForOne);
        if (from == 0 || amountIn == 0) return (0, 0);
        uint160 limit = uint160(
            zeroForOne ? from * (10_000 - BATCH_SQRT_BPS) / 10_000 : from * (10_000 + BATCH_SQRT_BPS) / 10_000
        );
        if (zeroForOne ? limit >= sqrtPrice : limit <= sqrtPrice) return (0, 0);
        BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        (int128 inDelta, int128 outDelta) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        spent = uint256(uint128(-inDelta));
        got = uint256(uint128(outDelta));
        manager.burn(address(this), input.toId(), spent);
        manager.mint(address(this), (zeroForOne ? key.currency1 : key.currency0).toId(), got);
        samples = (s & ((1 << 208) - 1)) | (block.number << 208); // this block's batch
    }

    /// Records `sqrtPrice` as the main duel's price at the start of this block, once per block (the first observation
    /// of a block comes before any swap of it has moved the price), and returns the samples word.
    function _sample(uint160 sqrtPrice) internal returns (uint256 s) {
        s = samples;
        if ((s >> 168) & 0xffffffffff == block.number) return s;
        s = (s & (0xffffffffff << 208)) | (block.number << 168) | ((s << SAMPLE_BITS) & ((1 << 168) - 1)) | _pack(sqrtPrice);
        samples = s;
    }

    /// The reference price of a batch from the samples in `s`: the most hook-favourable of the three latest sampled
    /// blocks' start prices (selling currency0 the price falls: the highest; else the lowest). 0 while fewer than three
    /// blocks are sampled or a batch already swapped there this block.
    function _reference(uint256 s, bool zeroForOne) internal view returns (uint256 from) {
        if (s >> 208 == block.number || (s >> (2 * SAMPLE_BITS)) & ((1 << SAMPLE_BITS) - 1) == 0) return 0;
        for (uint256 i; i < 3; i++) {
            uint256 p = _unpack((s >> (i * SAMPLE_BITS)) & ((1 << SAMPLE_BITS) - 1));
            if (i == 0 || (zeroForOne ? p > from : p < from)) from = p;
        }
    }

    /// A sqrt price as an 8-bit exponent and a 48-bit mantissa (a rounding of 2^-47, nothing next to the 0.1% band).
    function _pack(uint160 p) internal pure returns (uint256) {
        uint256 v = p;
        uint256 e;
        if (v >= 1 << 112) (v, e) = (v >> 64, 64);
        if (v >= 1 << 80) (v, e) = (v >> 32, e + 32);
        if (v >= 1 << 64) (v, e) = (v >> 16, e + 16);
        if (v >= 1 << 56) (v, e) = (v >> 8, e + 8);
        if (v >= 1 << 52) (v, e) = (v >> 4, e + 4);
        if (v >= 1 << 50) (v, e) = (v >> 2, e + 2);
        if (v >= 1 << 49) (v, e) = (v >> 1, e + 1);
        if (v >= 1 << 48) (v, e) = (v >> 1, e + 1);
        return e << 48 | v;
    }

    function _unpack(uint256 packed) internal pure returns (uint256) {
        return (packed & ((1 << 48) - 1)) << (packed >> 48);
    }

    function _mainKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = imd < imduel ? (imd, imduel) : (imduel, imd);
        return PoolKey(c0, c1, mainFee, mainSpacing, IHooks(address(this)));
    }

    function _minBatch(Currency c) internal view returns (uint256) {
        return c == imd ? minImd : c == imduel ? minImduel : type(uint256).max;
    }

    // ---------------------------------------------------------------- moves: every buy bids

    /// The game side of a swap: a move whose window has closed is played first; then this trade bids for its team's
    /// next move (the move being bid for now, if its team is to move) and takes the top spot if it pays more than
    /// RAISE_PCT over the current top; a trade of the other team after TURN_TIMEOUT of silence opens the silent side's
    /// move at 0%; then a slice batch converts if this pool's pile is ready.
    function _play(PoolId id, PoolKey calldata key, Game storage g, bool zeroForOne, BalanceDelta delta,
        bytes calldata hookData, uint160 sqrtPrice, uint256 liquidity) internal
    {
        uint256 mover = teamOf(g.slice, g.gameNo, g.ply & 1 == 1);
        if (g.bids[mover].open && block.number > g.closeBlock) {
            _resolve(id, key, g, mover);
            mover = teamOf(g.slice, g.gameNo, g.ply & 1 == 1);
        }
        uint256 team = zeroForOne ? 1 : 0; // the token bought
        TopBid storage b = g.bids[team];
        (uint256 paid, uint256 got) = team == 1
            ? (_abs(delta.amount0()), _abs(delta.amount1()))
            : (_abs(delta.amount1()), _abs(delta.amount0()));
        if (team == mover) {
            bool late = block.number > g.closeBlock;
            // a move whose window closed but that couldn't be played (the engine failed twice; it shouldn't) takes
            // no more bids
            if (!(late && b.open) && _beats(paid, b)) {
                if (late) g.closeBlock = uint40(block.number); // the window passed without a bid: this block is it
                _bid(id, g, team, g.ply, _trade(team, paid, got, hookData, sqrtPrice, liquidity));
            }
        } else {
            if (_beats(paid, b)) _bid(id, g, team, g.ply + 1, _trade(team, paid, got, hookData, sqrtPrice, liquidity));
            if (!g.bids[mover].open && block.timestamp >= g.turnStart + TURN_TIMEOUT) {
                // the silent side's move, at 0% for nobody; a real bid in this block takes it
                g.closeBlock = uint40(block.number);
                _bid(id, g, mover, g.ply, Trade(0, 0, address(0), 0));
            }
        }
        Currency s = g.slice == 0 ? key.currency0 : key.currency1;
        if (pile[s.toId()] >= _minBatch(s)) {
            try this.convertBatch{gas: CONVERT_GAS}(s) {} catch {}
        }
    }

    /// The trade a bid is made with: its owner (_owner) and its strength from its share of the in-range depth of the
    /// token it paid with, at the swap's start price.
    function _trade(uint256 team, uint256 paid, uint256 got, bytes calldata hookData, uint160 sqrtPrice,
        uint256 liquidity) internal view returns (Trade memory)
    {
        uint256 depth = team == 1
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPrice)
            : FullMath.mulDiv(liquidity, sqrtPrice, 1 << 96);
        return Trade(paid, got * PAYOUT_CAP, _owner(hookData), Strength.fromShare(paid, depth));
    }

    /// Who a trade bids for: the address in its hookData, 20 bytes packed or 32 bytes ABI-encoded (a zero address
    /// counts as none), else the wallet that signed the transaction, so a trade through any router or aggregator
    /// earns. Known and accepted: a trade relayed for a smart-contract wallet without hookData credits the relayer.
    function _owner(bytes calldata hookData) internal view returns (address owner) {
        if (hookData.length == 20) owner = address(bytes20(hookData));
        else if (hookData.length == 32 && uint256(bytes32(hookData)) <= type(uint160).max) owner = address(uint160(uint256(bytes32(hookData))));
        if (owner == address(0)) owner = tx.origin;
    }

    /// Whether a trade that paid `paid` takes the top spot from bid `b`: there is none, or it pays more than RAISE_PCT over it.
    function _beats(uint256 paid, TopBid storage b) internal view returns (bool) {
        return !b.open || paid * 100 > uint256(b.size) * (100 + RAISE_PCT);
    }

    /// Makes `t` team `team`'s top bid for half-move `ply`.
    function _bid(PoolId id, Game storage g, uint256 team, uint16 ply, Trade memory t) internal {
        TopBid storage b = g.bids[team];
        (b.owner, b.strength, b.open, b.size, b.cap) = (t.owner, t.strength, true, uint128(t.size), uint128(t.cap));
        emit Bid(id, g.gameNo, ply, t.owner, t.size, t.strength);
    }

    /// Plays the side to move's move (team `mover`) at its top bid's strength. The dice are the hash of the window's
    /// last block, which didn't exist while anyone could still bid, except for that block's builder (see the contract
    /// notes). A move whose block hash the chain no longer serves
    /// (after 8,191 blocks, about a day) becomes a timeout move in this block. If the engine fails (it shouldn't), a
    /// seeded legal move is played at 0%; if that fails too, the move stays queued. An engine starved by the trade's
    /// gas limit reverts the trade, so gas estimates include the move.
    function _resolve(PoolId id, PoolKey calldata key, Game storage g, uint256 mover) internal {
        bytes32 h = _hashOf(g.closeBlock);
        if (h == 0) {
            g.closeBlock = uint40(block.number);
            return _bid(id, g, mover, g.ply, Trade(0, 0, address(0), 0));
        }
        TopBid memory b = g.bids[mover];
        Trade memory t = Trade(b.size, b.cap, b.owner, b.strength);
        (bool ok, bool fell, uint16 m, Rules.Played memory r) = _choose(id, g, t, h);
        if (fell) emit EngineFailed(id, g.gameNo, g.ply);
        if (!ok) return; // the move stays queued
        if (fell) t.strength = 0;
        _apply(id, g, m, r, t);
        _payBounty(id, key, g, mover, t);
    }

    /// The move a bid plays: the engine's at the bid's strength with dice from `h`; if the engine fails (it shouldn't),
    /// a seeded legal move (`fell`); if that fails too, none (`ok` false). An engine starved by the trade's gas limit
    /// reverts the trade.
    function _choose(PoolId id, Game storage g, Trade memory t, bytes32 h)
        internal
        view
        returns (bool ok, bool fell, uint16 m, Rules.Played memory r)
    {
        uint256 seed = uint256(keccak256(abi.encode(h, id, g.gameNo, g.ply, t.owner, t.size)));
        bool black = g.ply & 1 == 1;
        (uint32 own, uint32 other) = black ? (g.blackState, g.whiteState) : (g.whiteState, g.blackState);
        (ok, m, r) = _engine(ENGINE_GAS, abi.encodeCall(IChessEngine.play,
            (g.board, own, other, black, uint256(t.strength), seed, _history(id, g.ply, g.quiet), g.gameNo, g.quiet)));
        if (ok) return (ok, false, m, r);
        _enoughGas(ENGINE_GAS);
        (ok, m, r) = _engine(FALLBACK_GAS, abi.encodeCall(IChessEngine.playAny, (g.board, own, other, black, seed)));
        if (!ok) _enoughGas(FALLBACK_GAS);
        return (ok, true, m, r);
    }

    /// The move the side to move will play, exactly as the next trade will play it, given the hash `h` of its window's
    /// last block: fixed as soon as that block is complete, which is before the chain can read the hash itself (false
    /// before that block, or without a bid). A view for the site to show each move as soon as it is fixed: called at the
    /// latest block, it runs after all of that block's trades. A caller inside the closing block itself gets an answer
    /// a later trade in that block can still change (it can still take the top bid).
    function previewMove(PoolId id, bytes32 h) external view returns (bool ready, uint16 move) {
        Game storage g = games[id];
        TopBid memory b = g.bids[teamOf(g.slice, g.gameNo, g.ply & 1 == 1)];
        if (!b.open || block.number < g.closeBlock) return (false, 0);
        (bool ok,, uint16 m,) = _choose(id, g, Trade(b.size, b.cap, b.owner, b.strength), h);
        return (ok, m);
    }

    /// The hash of block `n` (an earlier block), or 0 once the chain no longer serves it.
    function _hashOf(uint256 n) internal view returns (bytes32 h) {
        if (block.number - n <= 256) return blockhash(n);
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(n));
        if (ok && out.length == 32) h = abi.decode(out, (bytes32));
    }

    /// After a failed engine call: if it failed because the trade's gas limit starved it (63/64 rule), revert.
    function _enoughGas(uint256 cap) internal view {
        if (gasleft() < cap / 63) revert NotEnoughGas();
    }

    /// Calls the engine with a gas cap; ok only for a well-formed answer.
    function _engine(uint256 gasCap, bytes memory data) internal view returns (bool, uint16, Rules.Played memory r) {
        (bool ok, bytes memory result) = address(engine).staticcall{gas: gasCap}(data);
        if (!ok || result.length != 224) return (false, 0, r);
        uint16 m;
        (m, r) = abi.decode(result, (uint16, Rules.Played));
        return (m < 4096, m, r);
    }

    /// This side's last eight positions, most recent first. None can repeat until four reversible half-moves have
    /// passed (the position after this move needs quiet >= 4), so they are skipped before that.
    function _history(PoolId id, uint16 ply, uint16 quiet) internal view returns (uint64[8] memory previous) {
        if (quiet < 3) return previous;
        (uint256 lo, uint256 hi) = _lanes(id, ply);
        for (uint256 i; i < 8; i++) previous[i] = _key(lo, hi, ((ply + 14 - i * 2) % 16) >> 1);
    }

    /// Records a move played by the rules (`r`: the new position and how the game stands), clears its bid and opens
    /// the next move's window.
    function _apply(PoolId id, Game storage g, uint16 move, Rules.Played memory r, Trade memory t) internal {
        bool black = g.ply & 1 == 1;
        g.bids[teamOf(g.slice, g.gameNo, black)].open = false;
        uint256 board = g.board;
        uint8 captured = _captured(board, move);
        bool pawn = Chess.typeAt(board, move >> 6) == 1;
        g.board = r.board;
        (g.whiteState, g.blackState) = black ? (r.other, r.mover) : (r.mover, r.other);
        g.quiet = (captured != 0 || pawn) ? 0 : g.quiet + 1;
        (g.movePly, g.moveGameNo, g.moveOwner, g.moveStrength) = (g.ply, g.gameNo, t.owner, t.strength);
        (g.moveCaptured, g.moveCheck, g.moveBlack, g.moveResult) = (captured, r.check, black, 0);
        emit Moved(id, g.gameNo, g.ply, move, t.owner, t.size, t.strength, captured, r.check);
        g.ply++;
        _openTurn(g);

        // game end: the side now to move has no legal move, or a draw rule applies
        uint8 result;
        if (r.status == 2) {
            result = black ? 2 : 1;
        } else {
            uint8 reason;
            if (r.status == 1) reason = 1;
            else if (r.insufficient) reason = 2;
            else if (_repeated(id, g)) reason = 3;
            else if (g.quiet >= MAX_QUIET_PLY) reason = 4;
            else if (g.ply >= MAX_PLY) reason = 5;
            if (reason != 0) {
                result = 3;
                emit DrawTriggered(id, g.gameNo, reason, g.ply);
            }
        }
        if (result != 0) {
            g.moveResult = result;
            emit GameOver(id, g.gameNo, result, g.ply);
            g.gameNo++;
            _newGame(id, g);
        } else {
            // the position after this move joins the repetition memory, in the lane of its half-move
            (uint256 slot, uint256 shift) = _laneAt(g.ply - 1);
            uint256 w = recentPositions[id][slot];
            uint64 k = Chess.positionKey(g.board, g.whiteState, g.blackState, g.ply & 1 == 1, g.gameNo);
            recentPositions[id][slot] = (w & ~(uint256(type(uint64).max) << shift)) | (uint256(k) << shift);
        }
    }

    /// Records the reward of the owner of the move just played, in its team's token from its team's chest, at most
    /// PAYOUT_CAP times what the bid's trade received. Timeout moves pay nobody.
    function _payBounty(PoolId id, PoolKey calldata key, Game storage g, uint256 team, Trade memory t) internal {
        if (t.owner == address(0)) return;
        uint256 bps = bountyBps(g.moveCaptured, g.moveCheck, g.moveResult == (g.moveBlack ? 2 : 1));
        if (bps == 0) return;
        uint256 amount = chest(id, team) * bps / 10_000;
        if (amount > t.cap) amount = t.cap;
        if (amount == 0) return;
        _takeChest(id, team, amount);
        _pay(id, g, key, team, t.owner, amount);
    }

    // ---------------------------------------------------------------- position memory

    /// Ring slot and bit offset of the lane for half-move `ply`.
    function _laneAt(uint256 ply) internal pure returns (uint256 slot, uint256 shift) {
        uint256 l = ply % 16;
        uint256 k = l >> 1;
        (slot, shift) = ((l & 1) * 2 + (k >> 2), (k & 3) * 64);
    }

    /// The two ring slots holding the lanes with the same parity as `ply`.
    function _lanes(PoolId id, uint256 ply) internal view returns (uint256 lo, uint256 hi) {
        uint256 s = (ply & 1) * 2;
        (lo, hi) = (recentPositions[id][s], recentPositions[id][s + 1]);
    }

    /// The k-th (0-7) key of one parity: half-move index k of that parity's lanes.
    function _key(uint256 lo, uint256 hi, uint256 k) internal pure returns (uint64) {
        return uint64((k < 4 ? lo : hi) >> ((k & 3) * 64));
    }

    function _repeated(PoolId id, Game storage g) internal view returns (bool) {
        // A position needs at least four reversible half-moves to recur (each side out and back), and nothing before
        // the last capture or pawn move can recur; skips the reads on most swaps.
        if (g.quiet < 4) return false;
        uint64 k = Chess.positionKey(g.board, g.whiteState, g.blackState, g.ply & 1 == 1, g.gameNo);
        uint256 seen;
        if (g.board == Chess.START_BOARD && g.whiteState == Chess.START_WHITE && g.blackState == Chess.START_BLACK
            && g.ply & 1 == 0) seen = 1;
        // the key's side to move is g.ply's; those positions were made by half-moves of the other parity
        (uint256 lo, uint256 hi) = _lanes(id, g.ply + 1);
        for (uint256 i; i < 8; i++) {
            if (_key(lo, hi, i) == k && ++seen == 2) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- small helpers

    /// Which currency (0 or 1) the swap specified: the input for exact input, the output for exact output.
    function _specified(SwapParams calldata params) internal pure returns (uint256) {
        return params.zeroForOne == (params.amountSpecified < 0) ? 0 : 1;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    /// Piece type captured by `move` on `board`: the piece on the target square, or a pawn taken en passant.
    function _captured(uint256 board, uint16 move) internal pure returns (uint8) {
        uint256 from = move >> 6;
        uint256 to = move & 63;
        uint8 target = Chess.typeAt(board, to);
        if (target != 0) return target;
        if (Chess.typeAt(board, from) == 1 && (from & 7) != (to & 7)) return 1; // diagonal pawn move to an empty square
        return 0;
    }

    function _newGame(PoolId id, Game storage g) internal {
        g.board = Chess.START_BOARD;
        g.whiteState = Chess.START_WHITE;
        g.blackState = Chess.START_BLACK;
        g.ply = 0;
        g.quiet = 0;
        _openTurn(g);
        emit GameStarted(id, g.gameNo);
    }

    /// The side to move's move takes bids from this block through `turnBlocks` blocks.
    function _openTurn(Game storage g) internal {
        (g.turnStart, g.closeBlock) = (uint32(block.timestamp), uint40(block.number + turnBlocks - 1));
    }

    function _onlyManager() internal view {
        if (msg.sender != address(manager)) revert NotManager();
    }

    function _onlySelf() internal view {
        if (msg.sender != address(this)) revert NotSelf();
    }

    // transient storage: 0 the re-entry lock, 1-2 the pool state read in beforeSwap for afterSwap

    function _locked() internal view returns (bool l) {
        assembly ("memory-safe") {
            l := tload(0)
        }
    }

    function _lock(bool on) internal {
        assembly ("memory-safe") {
            tstore(0, on)
        }
    }

    /// The pool's state at the swap's start and the fee taken before it, for afterSwap. `liquidity` is a pool's uint128
    /// and `taken` is never negative, so they share a slot.
    function _stash(uint160 sqrtPrice, uint256 liquidity, uint256 chestIdx, int128 taken) internal {
        uint256 fee = uint128(taken);
        assembly ("memory-safe") {
            tstore(1, or(sqrtPrice, shl(160, chestIdx)))
            tstore(2, or(liquidity, shl(128, fee)))
        }
    }

    function _unstash() internal view returns (uint160 sqrtPrice, uint256 liquidity, uint256 chestIdx, int128 taken) {
        assembly ("memory-safe") {
            let w := tload(1)
            sqrtPrice := and(w, 0xffffffffffffffffffffffffffffffffffffffff)
            chestIdx := shr(160, w)
            let v := tload(2)
            liquidity := and(v, 0xffffffffffffffffffffffffffffffff)
            taken := shr(128, v)
        }
    }
}
