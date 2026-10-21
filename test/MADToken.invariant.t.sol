// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice Drives the token with random transfers, approvals and allowance spends among a fixed set
/// of actors, including calls that must fail. It keeps its own ledger of what every actor should
/// hold and be allowed to spend, built only from the ERC-20 rules, and checks that a call that should
/// revert reverts with the right error and leaves every balance and allowance as it was.
contract MADHandler is Test {
    MADToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostMoved;
    uint256 public calls;
    uint256 public successes;
    uint256 public expectedReverts;

    constructor(MADToken token_, address[] memory actors_, address holder) {
        token = token_;
        actors = actors_;
        ghostBalance[holder] = token_.TOTAL_SUPPLY();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        // Mostly within balance, sometimes one past it, sometimes anything.
        if (amount % 4 != 0) amount = bound(amount, 0, held);
        else if (amount % 8 == 0) amount = held + 1;

        vm.prank(from);
        if (amount > held) {
            try token.transfer(to, amount) {
                revert("transfer above balance succeeded");
            } catch (bytes memory reason) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount),
                    "wrong revert for transfer above balance"
                );
                expectedReverts++;
            }
            return;
        }
        assertTrue(token.transfer(to, amount), "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (from != to) ghostMoved += amount;
        successes++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Include the infinite allowance, which transferFrom must never decrement.
        if (amount % 5 == 0) amount = type(uint256).max;
        else amount = bound(amount, 0, token.TOTAL_SUPPLY() * 2);

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        successes++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 held = ghostBalance[from];
        uint256 cap = allowed < held ? allowed : held;
        if (amount % 4 != 0) amount = bound(amount, 0, cap);
        else if (amount % 8 == 0) amount = cap == type(uint256).max ? cap : cap + 1;
        else amount = bound(amount, 0, token.TOTAL_SUPPLY() + 1);

        vm.prank(spender);
        if (amount > allowed) {
            try token.transferFrom(from, to, amount) {
                revert("transferFrom above allowance succeeded");
            } catch (bytes memory reason) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount),
                    "wrong revert for transferFrom above allowance"
                );
                expectedReverts++;
            }
            return;
        }
        if (amount > held) {
            try token.transferFrom(from, to, amount) {
                revert("transferFrom above balance succeeded");
            } catch (bytes memory reason) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount),
                    "wrong revert for transferFrom above balance"
                );
                expectedReverts++;
            }
            return;
        }
        assertTrue(token.transferFrom(from, to, amount), "transferFrom returned false");
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (from != to) ghostMoved += amount;
        successes++;
    }

    /// @dev The zero address can never receive, and the zero spender can never be approved.
    function sendToZero(uint256 fromSeed, uint256 amount) external {
        calls++;
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.TOTAL_SUPPLY());
        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            expectedReverts++;
        }
        vm.prank(from);
        try token.approve(address(0), amount) {
            revert("approve of the zero spender succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            expectedReverts++;
        }
    }

    /// @dev Tries every plausible privileged selector from a random actor (the deployer among them).
    /// None exists, so each call must fail and nothing may move.
    function tryPrivileged(uint256 callerSeed, uint256 selectorSeed, uint256 victimSeed, uint256 amount) external {
        calls++;
        address caller = _actor(callerSeed);
        address victim = _actor(victimSeed);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "seize(address,uint256)",
            "freeze(address,uint256)",
            "blacklist(address,uint256)",
            "pause(address,uint256)",
            "transferOwnership(address,uint256)",
            "rescue(address,uint256)",
            "setFee(address,uint256)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[selectorSeed % signatures.length], victim, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged selector exists");
        expectedReverts++;
    }
}

/// @notice Invariants over random sequences of the handler's calls. The token keeps balances for
/// every holder, so the fixed supply must stay fixed and fully accounted for, and every balance and
/// allowance must be exactly what the ERC-20 rules say it is after any sequence.
contract MADTokenInvariantTest is Test {
    MADToken internal token;
    MADHandler internal handler;
    address internal deployer = makeAddr("deployer");
    address[] internal actors;

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        handler = new MADHandler(token, actors, deployer);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = MADHandler.transfer.selector;
        selectors[1] = MADHandler.approve.selector;
        selectors[2] = MADHandler.transferFrom.selector;
        selectors[3] = MADHandler.sendToZero.selector;
        selectors[4] = MADHandler.tryPrivileged.selector;
        selectors[5] = MADHandler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "tokens left or entered the actor set");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance drifted from the ledger");
            assertLe(token.balanceOf(actors[i]), token.TOTAL_SUPPLY());
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance drifted from the ledger"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
    }

    /// @dev The handler accounts for every call as a success or an expected revert; anything else
    /// would have failed inside the handler.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyCallAccountedFor() public view {
        assertLe(handler.successes() + handler.expectedReverts(), handler.calls() * 2);
        assertGe(handler.successes() + handler.expectedReverts(), handler.calls());
    }
}
