// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {POEDBToken} from "../src/POEDBToken.sol";
import {LaunchSimulator} from "./helpers/LaunchSimulator.sol";

/// forge-config: default.fuzz.runs = 1000
/// @dev Inputs the main suite does not reach: value on construction, the bytecode itself, raw
/// return data, selectors the token does not implement, one-unit boundaries, and several spenders
/// competing for one balance.
contract POEDBTokenEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant EIP170_LIMIT = 24_576;

    POEDBToken private token;
    address private alice;
    address private bob;
    address private carol;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new POEDBToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
    }

    // ----------------------------------------------------------------- construction and bytecode

    function test_constructorRejectsNativeValue() public {
        LaunchSimulator deployer = new LaunchSimulator();
        vm.deal(address(this), 2 ether);
        address withValue = deployer.deployWithValue{value: 1}();
        assertEq(withValue, address(0), "a non-payable constructor accepted value");
        address withoutValue = deployer.deployWithValue{value: 0}();
        assertGt(withoutValue.code.length, 0);
        assertEq(POEDBToken(withoutValue).balanceOf(address(deployer)), SUPPLY);
        assertEq(address(withoutValue).balance, 0);
    }

    function test_runtimeFitsEip170AndHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, EIP170_LIMIT);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL in runtime");
            assertTrue(op != 0xF2, "CALLCODE in runtime");
            assertTrue(op != 0xFF, "SELFDESTRUCT in runtime");
        }
    }

    function test_runtimeIsIdenticalAcrossDeployments() public {
        vm.prank(alice);
        POEDBToken other = new POEDBToken();
        assertEq(keccak256(address(other).code), keccak256(address(token).code));
        assertEq(other.totalSupply(), token.totalSupply());
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------- raw ABI surface

    function test_mutatingCallsReturnExactlyOneTrueWord() public {
        token.approve(alice, 3);
        bytes[3] memory calls = [
            abi.encodeCall(token.transfer, (bob, 1)),
            abi.encodeCall(token.approve, (bob, 1)),
            abi.encodeCall(token.transferFrom, (address(this), bob, 0))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(token).call(calls[i]);
            assertTrue(ok);
            assertEq(ret.length, 32);
            assertEq(abi.decode(ret, (bool)), true);
            assertEq(uint256(bytes32(ret)), 1, "return word is not a clean boolean");
        }
        vm.prank(alice);
        (bool okFrom, bytes memory retFrom) =
            address(token).call(abi.encodeCall(token.transferFrom, (address(this), carol, 3)));
        assertTrue(okFrom);
        assertEq(retFrom.length, 32);
        assertEq(uint256(bytes32(retFrom)), 1);
        assertEq(token.balanceOf(carol), 3);
    }

    function test_viewCallsReturnWellFormedData() public view {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeCall(token.decimals, ()));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(uint256(bytes32(ret)), 18);

        (ok, ret) = address(token).staticcall(abi.encodeCall(token.totalSupply, ()));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), SUPPLY);

        (ok, ret) = address(token).staticcall(abi.encodeCall(token.name, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "poedb");
        assertEq(bytes(abi.decode(ret, (string))).length, 5);

        (ok, ret) = address(token).staticcall(abi.encodeCall(token.symbol, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "POEDB");
        assertEq(bytes(abi.decode(ret, (string))).length, 5);
    }

    function _isImplemented(bytes4 selector) private view returns (bool) {
        return selector == token.transfer.selector || selector == token.approve.selector
            || selector == token.transferFrom.selector || selector == token.balanceOf.selector
            || selector == token.allowance.selector || selector == token.totalSupply.selector
            || selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.INITIAL_SUPPLY.selector;
    }

    function testFuzz_unimplementedSelectorsRevertAndChangeNothing(
        bytes4 rawSelector,
        bytes calldata args,
        uint96 value
    ) public {
        bytes4 selector = rawSelector;
        while (_isImplemented(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        token.transfer(alice, 1 ether);
        vm.deal(address(this), value);

        (bool ok,) = address(token).call{value: value}(abi.encodePacked(selector, args));
        assertFalse(ok, "an unimplemented selector was accepted");
        vm.prank(alice);
        (bool okHolder,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(okHolder, "an unimplemented selector was accepted from a holder");

        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
    }

    function test_implementedSelectorsRejectValue() public {
        vm.deal(address(this), 1 ether);
        bytes[5] memory calls = [
            abi.encodeCall(token.transfer, (bob, 1)),
            abi.encodeCall(token.approve, (bob, 1)),
            abi.encodeCall(token.transferFrom, (address(this), bob, 0)),
            abi.encodeCall(token.balanceOf, (bob)),
            abi.encodeCall(token.totalSupply, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call{value: 1}(calls[i]);
            assertFalse(ok, "a non-payable function accepted value");
        }
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(address(this), bob), 0);
    }

    // ----------------------------------------------------------------------- one-unit boundaries

    function test_oneUnitTransferAndExactBoundaries() public {
        token.transfer(alice, 1);
        assertEq(token.balanceOf(alice), 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_allowanceOneBelowAmountRevertsAndExactAmountSucceeds() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 9);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 9, 10));
        vm.prank(bob);
        token.transferFrom(alice, carol, 10);
        assertEq(token.allowance(alice, bob), 9);

        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 10));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(carol), 10);
    }

    function test_balanceOneBelowAmountRevertsEvenWithAllowance() public {
        token.transfer(alice, 9);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 9, 10));
        vm.prank(bob);
        token.transferFrom(alice, carol, 10);
        assertEq(token.allowance(alice, bob), 10);
        assertEq(token.balanceOf(alice), 9);
    }

    function test_maxAllowanceMinusOneIsFiniteAndDecrements() public {
        uint256 nearlyInfinite = type(uint256).max - 1;
        token.approve(alice, nearlyInfinite);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), alice), nearlyInfinite - 1);
    }

    function test_infiniteAllowanceStillRequiresBalance() public {
        token.transfer(alice, 5);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5, 6));
        vm.prank(bob);
        token.transferFrom(alice, carol, 6);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(alice), 5);
    }

    // ------------------------------------------------------------------- approvals and spenders

    function test_approveFromZeroAddressReverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(alice, 1);
        assertEq(token.allowance(address(0), alice), 0);
    }

    function test_transferFromZeroAddressWithAmountRevertsOnAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ownerCanApproveSelfAndSpendThroughTransferFrom() public {
        token.approve(address(this), 4);
        assertTrue(token.transferFrom(address(this), bob, 4));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(bob), 4);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), bob, 1);
    }

    function test_transferFromEmitsOnlyTransfer() public {
        token.approve(alice, 10);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(address(this), bob, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than one event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 4);
        // The spent allowance is visible by reading, even without an Approval event.
        assertEq(token.allowance(address(this), alice), 6);
    }

    function test_spenderAllowanceDoesNotSurviveOwnerBalanceExhaustion() public {
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(bob, 10);
        token.approve(carol, 10);
        vm.stopPrank();

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 10));
        assertEq(token.allowance(alice, carol), 10, "an unrelated allowance changed");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(carol);
        token.transferFrom(alice, carol, 1);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(bob), 10);
    }

    function testFuzz_approveReplacesRatherThanAccumulates(uint256 first, uint256 second) public {
        token.approve(alice, first);
        assertEq(token.allowance(address(this), alice), first);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), alice, second);
        token.approve(alice, second);
        assertEq(token.allowance(address(this), alice), second);
        assertEq(token.allowance(alice, address(this)), 0, "allowance leaked in the other direction");
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_twoSpendersShareOneBalance(uint256 rawHeld, uint256 rawFirst, uint256 rawSecond) public {
        uint256 held = bound(rawHeld, 1, SUPPLY);
        uint256 first = bound(rawFirst, 0, held);
        uint256 second = bound(rawSecond, 0, held);
        token.transfer(alice, held);
        vm.startPrank(alice);
        token.approve(bob, first);
        token.approve(carol, second);
        vm.stopPrank();

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, first));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.allowance(alice, carol), second);

        uint256 left = held - first;
        if (second <= left) {
            vm.prank(carol);
            assertTrue(token.transferFrom(alice, carol, second));
            assertEq(token.balanceOf(carol), second);
            assertEq(token.balanceOf(alice), left - second);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, left, second));
            vm.prank(carol);
            token.transferFrom(alice, carol, second);
            assertEq(token.balanceOf(carol), 0);
            assertEq(token.balanceOf(alice), left);
            assertEq(token.allowance(alice, carol), second);
        }
        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(address(this)),
            SUPPLY
        );
    }

    function testFuzz_chainedTransfersConserveSupply(uint8 rawHops, uint256 seed) public {
        uint256 hops = bound(rawHops, 1, 12);
        address previous = address(this);
        uint256 carried = SUPPLY;
        address[] memory path = new address[](hops);
        uint256[] memory kept = new uint256[](hops);
        for (uint256 i; i < hops; ++i) {
            address next = makeAddr(string.concat("hop ", vm.toString(i)));
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 0, carried);
            vm.prank(previous);
            assertTrue(token.transfer(next, amount));
            assertEq(token.balanceOf(next), amount);
            path[i] = next;
            kept[i] = amount;
            if (i > 0) kept[i - 1] -= amount;
            carried = amount;
            previous = next;
        }
        uint256 sum = token.balanceOf(address(this));
        for (uint256 i; i < hops; ++i) {
            assertEq(token.balanceOf(path[i]), kept[i]);
            sum += token.balanceOf(path[i]);
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_balancesNeverExceedSupply(address a, address b, uint256 rawX, uint256 rawY) public {
        // Any pair of recipients, including equal ones and the test contract itself; only zero is excluded by
        // the token, so remap it rather than discard the run.
        if (a == address(0)) a = alice;
        if (b == address(0)) b = bob;
        uint256 x = bound(rawX, 0, SUPPLY);
        uint256 y = bound(rawY, 0, SUPPLY - x);
        assertTrue(token.transfer(a, x));
        assertTrue(token.transfer(b, y));
        assertLe(token.balanceOf(a), SUPPLY);
        assertLe(token.balanceOf(b), SUPPLY);
        assertLe(token.balanceOf(address(this)), SUPPLY);
        if (a != b && a != address(this) && b != address(this)) {
            assertEq(token.balanceOf(a) + token.balanceOf(b) + token.balanceOf(address(this)), SUPPLY);
        } else if (a == b && a != address(this)) {
            assertEq(token.balanceOf(a), x + y);
            assertEq(token.balanceOf(address(this)), SUPPLY - x - y);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
