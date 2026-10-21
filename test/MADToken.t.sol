// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice Stands in for the launch factory: deploys the token so that `msg.sender` of the
/// constructor is a contract, exactly as ProjectFactory.launchCustom does, and moves tokens on
/// request. Only the test drives it.
contract DeployerProbe {
    MADToken public token;

    function deploy() external returns (MADToken) {
        token = new MADToken();
        return token;
    }

    function move(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MADTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    MADToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new MADToken();
    }

    // ───────────────────────────── metadata and supply ─────────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Mutually Assured Destruction");
        assertEq(token.TOKEN_SYMBOL(), "MAD");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new MADToken();
    }

    /// @dev The launch deploys the token from a contract, so the deployer is a contract, not an EOA.
    function test_contractDeployerReceivesWholeSupplyAndCanMoveIt() public {
        DeployerProbe probe = new DeployerProbe();
        MADToken launched = probe.deploy();
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(probe)), SUPPLY);

        uint256 swarm = SUPPLY / 10;
        assertTrue(probe.move(alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(address(probe)), SUPPLY - swarm);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_constructorTakesNoArguments() public pure {
        // The creation code is exactly the compiled bytecode: no ABI-encoded arguments are appended,
        // so the launch manifest's constructorArgs for this token is empty.
        bytes memory code = type(MADToken).creationCode;
        assertGt(code.length, 0);
    }

    // ───────────────────────────── transfers: success ─────────────────────────────

    function test_transferMovesBalanceAndEmits() public {
        uint256 amount = 1_000 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(stranger);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_selfTransferKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 123 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_secondaryHolderCanTransferOnward() public {
        vm.prank(deployer);
        token.transfer(alice, 50 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 20 ether));
        assertEq(token.balanceOf(alice), 30 ether);
        assertEq(token.balanceOf(bob), 20 ether);
    }

    // ───────────────────────────── transfers: failure ─────────────────────────────

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        vm.prank(alice);
        token.transfer(bob, 11 ether);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        vm.prank(stranger);
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
    }

    // ───────────────────────────── allowances: success ─────────────────────────────

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 5 ether);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 5 ether));
        assertEq(token.allowance(deployer, alice), 5 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.approve(alice, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 2 ether);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);

        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 3 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 3 ether));

        assertEq(token.balanceOf(bob), 3 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 3 ether);
        assertEq(token.allowance(deployer, alice), 2 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 7 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 7 ether);
    }

    // ───────────────────────────── allowances: failure ─────────────────────────────

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1 ether));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1 ether, 1 ether + 1)
        );
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether + 1);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 100 ether));
        vm.prank(bob);
        token.transferFrom(alice, bob, 100 ether);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // ───────────────────────────── no privileged powers ─────────────────────────────

    /// @dev No function on the token can mint, burn another holder's tokens, pause, freeze or
    /// reassign anything. Every plausible admin selector is tried from a stranger and from the
    /// deployer: each call must fail (no such function) and leave supply and balances untouched.
    function test_noAdminSelectorExistsOrChangesState() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);

        string[18] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "seize(address)",
            "setMinter(address)",
            "setFee(uint256)",
            "upgradeTo(address)",
            "initialize(address)",
            "setTransfersEnabled(bool)"
        ];
        address[2] memory callers = [stranger, deployer];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);

        // The holder is still free to move what it holds.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000 ether));
        assertEq(token.balanceOf(bob), 1_000 ether);
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_plainCallsAndEtherAreRejected() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "token accepted an empty call");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 attempted) public {
        held = bound(held, 0, SUPPLY - 1);
        attempted = bound(attempted, held + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempted));
        vm.prank(alice);
        token.transfer(bob, attempted);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, spent)
            );
            token.transferFrom(deployer, bob, spent);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spent));
            assertEq(token.balanceOf(bob), spent);
            assertEq(token.allowance(deployer, alice), allowed - spent);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_chainedTransfersConserveSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(stranger, c);
        uint256 sum =
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(stranger);
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
