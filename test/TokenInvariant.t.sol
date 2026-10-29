// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDuelToken} from "../src/IMDuelToken.sol";

/// Random transfers, approvals and transferFroms between a few holders, the failing ones included. Every call that
/// should fail is asserted to fail with its error and to change nothing; every one that should succeed moves exactly
/// what it says.
contract TokenHandler is Test {
    IMDuelToken public immutable token;
    address[] public actors;
    // ghost: what each allowance should be
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public refused;

    constructor() {
        token = new IMDuelToken(); // the whole supply to this handler, as to the launch factory
        actors.push(address(this));
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA7));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 i) internal view returns (address) {
        return actors[i % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 value, bool toZero) external {
        address from = actor(fromSeed);
        address to = toZero ? address(0) : actor(toSeed);
        uint256 balance = token.balanceOf(from);
        value = bound(value, 0, balance + 10);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        if (to == address(0)) {
            vm.expectRevert(IMDuelToken.InvalidAddress.selector);
            token.transfer(to, value);
            refused++;
            return;
        }
        if (value > balance) {
            vm.expectRevert(IMDuelToken.InsufficientBalance.selector);
            token.transfer(to, value);
            refused++;
            return;
        }
        assertTrue(token.transfer(to, value));
        if (from == to) {
            assertEq(token.balanceOf(from), balance, "a self transfer changes nothing");
        } else {
            assertEq(token.balanceOf(from), balance - value);
            assertEq(token.balanceOf(to), toBefore + value);
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value, bool infinite) external {
        address owner = actor(ownerSeed);
        address spender = actor(spenderSeed);
        if (infinite) value = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        expectedAllowance[owner][spender] = value;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 value) external {
        vm.prank(actor(ownerSeed));
        vm.expectRevert(IMDuelToken.InvalidAddress.selector);
        token.approve(address(0), value);
        refused++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 value) external {
        address spender = actor(spenderSeed);
        address from = actor(fromSeed);
        address to = actor(toSeed);
        uint256 approved = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        value = bound(value, 0, balance + 10);
        vm.prank(spender);
        if (approved != type(uint256).max && approved < value) {
            vm.expectRevert(IMDuelToken.InsufficientAllowance.selector);
            token.transferFrom(from, to, value);
            refused++;
            return;
        }
        if (value > balance) {
            vm.expectRevert(IMDuelToken.InsufficientBalance.selector);
            token.transferFrom(from, to, value);
            refused++;
            return;
        }
        assertTrue(token.transferFrom(from, to, value));
        if (approved != type(uint256).max) expectedAllowance[from][spender] = approved - value;
        assertEq(token.allowance(from, spender), expectedAllowance[from][spender], "allowance spent exactly");
    }
}

contract TokenInvariantTest is Test {
    TokenHandler handler;
    IMDuelToken token;

    function setUp() public {
        handler = new TokenHandler();
        token = handler.token();
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixedAndHeldByTheActors() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether, "fixed supply");
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "every token is held by someone who was sent it");
        assertEq(token.balanceOf(address(0)), 0, "nothing at the zero address");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesAreExactlyWhatWasApprovedLessWhatWasSpent() public view {
        for (uint256 i; i < handler.actorCount(); i++) {
            for (uint256 j; j < handler.actorCount(); j++) {
                address o = handler.actors(i);
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.expectedAllowance(o, s));
            }
        }
    }

    function test_transferFromTheZeroAddressIsRefused() public {
        vm.prank(address(handler));
        token.approve(address(this), 1);
        vm.expectRevert(IMDuelToken.InvalidAddress.selector);
        token.transferFrom(address(0), address(1), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferOfMoreThanTheBalanceIsRefused(uint256 extra) public {
        extra = bound(extra, 1, type(uint256).max - token.totalSupply());
        uint256 value = token.totalSupply() + extra;
        vm.prank(address(handler));
        vm.expectRevert(IMDuelToken.InsufficientBalance.selector);
        token.transfer(address(1), value);
        assertEq(token.balanceOf(address(handler)), token.totalSupply());
    }
}
