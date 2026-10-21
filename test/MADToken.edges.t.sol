// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice Deploys the token through CREATE2 and moves the launch flows in one call, as the factory
/// does in one transaction.
contract Create2Launcher {
    function launch(bytes32 salt, address swarm, address pool, address remainder)
        external
        returns (MADToken token, uint256 heldAfterDeploy)
    {
        token = new MADToken{salt: salt}();
        heldAfterDeploy = token.balanceOf(address(this));
        uint256 supply = token.totalSupply();
        require(token.transfer(swarm, supply / 10), "swarm transfer");
        require(token.transfer(pool, (supply * 8_000) / 10_000), "pool transfer");
        require(token.transfer(remainder, token.balanceOf(address(this))), "remainder transfer");
    }
}

contract MADTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    MADToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();
    }

    // ───────────────────────────── deployment ─────────────────────────────

    function test_create2LaunchFlowsArriveExactly() public {
        Create2Launcher launcher = new Create2Launcher();
        address swarm = makeAddr("swarm");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");
        bytes32 salt = bytes32(uint256(42));
        address predicted = vm.computeCreate2Address(salt, keccak256(type(MADToken).creationCode), address(launcher));

        (MADToken launched, uint256 held) = launcher.launch(salt, swarm, pool, remainder);
        assertEq(address(launched), predicted);
        assertEq(held, SUPPLY);
        assertEq(launched.balanceOf(swarm), 100_000_000 ether);
        assertEq(launched.balanceOf(pool), 800_000_000 ether);
        assertEq(launched.balanceOf(remainder), 100_000_000 ether);
        assertEq(launched.balanceOf(address(launcher)), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_sameSaltCannotDeployTwice() public {
        Create2Launcher launcher = new Create2Launcher();
        launcher.launch(bytes32(0), alice, bob, alice);
        vm.expectRevert();
        launcher.launch(bytes32(0), alice, bob, alice);
    }

    function test_eachDeploymentIsIndependent() public {
        vm.prank(alice);
        MADToken second = new MADToken();
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    // ───────────────────────────── transferFrom edges ─────────────────────────────

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, alice), 1 ether, "a failed transferFrom spent allowance");
    }

    function test_ownerNeedsAllowanceToTransferFromItself() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
    }

    function test_failedTransferFromLeavesAllowanceAndBalances() public {
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(deployer);
        token.transfer(alice, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        vm.prank(bob);
        token.transferFrom(alice, bob, 6 ether);

        assertEq(token.allowance(alice, bob), 10 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_exactAllowanceForWholeSupplyDrainsToZero() public {
        vm.prank(deployer);
        token.approve(alice, SUPPLY);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, SUPPLY));
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    function test_zeroAmountTransferFromNeedsNoAllowance() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_transferAboveTotalSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(deployer);
        token.transfer(alice, SUPPLY + 1);
    }

    function test_maxUintTransferReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
    }

    function test_revokedAllowanceBlocksSpender() public {
        vm.startPrank(deployer);
        token.approve(alice, type(uint256).max);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    // ───────────────────────────── zero-address caller ─────────────────────────────

    function test_zeroAddressSenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
    }

    function test_zeroAddressApproverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(alice, 1);
    }

    // ───────────────────────────── stuck tokens ─────────────────────────────

    /// @dev Tokens sent to the token contract are accepted and nobody can recover them: there is no
    /// rescue function and the contract cannot approve or transfer on its own behalf. Documented in
    /// the README as a holder's responsibility; the supply still counts them.
    function test_tokensSentToTheContractStayThere() public {
        vm.prank(deployer);
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(address(token), deployer, 1);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveRoundTrips(address owner, address spender, uint256 amount) public {
        owner = address(uint160(bound(uint160(owner), 1, type(uint160).max)));
        spender = address(uint160(bound(uint160(spender), 1, type(uint160).max)));
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_infiniteAllowanceSpendsAnyAmount(uint256 amount, uint256 again) public {
        amount = bound(amount, 0, SUPPLY);
        again = bound(again, 0, SUPPLY - amount);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, amount);
        token.transferFrom(deployer, bob, again);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), amount + again);
        assertEq(token.balanceOf(deployer), SUPPLY - amount - again);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferIsNoOp(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferBackRestores(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
