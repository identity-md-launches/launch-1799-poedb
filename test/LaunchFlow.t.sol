// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {POEDBToken} from "../src/POEDBToken.sol";
import {LaunchSimulator} from "./helpers/LaunchSimulator.sol";

/// forge-config: default.fuzz.runs = 1000
/// @dev The launch as one transaction: deploy, then split the supply, in a single call. Covers the
/// flows the factory, the distributor and the pool manager perform, and the ways each can fail.
contract LaunchFlowTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant POOL_BPS = 8_800;

    LaunchSimulator private factory;
    address private distributor;
    address private poolManager;
    address private requester;
    address private caller;
    address private origin;

    function setUp() public {
        factory = new LaunchSimulator();
        distributor = makeAddr("distributor");
        poolManager = makeAddr("pool manager");
        requester = makeAddr("requester");
        caller = makeAddr("factory caller");
        origin = makeAddr("transaction origin");
    }

    function _plan(uint256 poolBps) private view returns (LaunchSimulator.Plan memory) {
        return LaunchSimulator.Plan(distributor, poolManager, requester, poolBps);
    }

    function test_oneTransactionLaunchSplitsTheSupplyExactly() public {
        bytes32 salt = bytes32(uint256(7));
        address predicted = factory.predict(salt);
        assertEq(predicted.code.length, 0);

        LaunchSimulator.Result memory r = factory.launch(salt, _plan(POOL_BPS));
        POEDBToken token = r.token;

        assertEq(address(token), predicted);
        assertEq(r.supply, SUPPLY);
        assertEq(r.swarm, 100_000_000 ether);
        assertEq(r.pool, 880_000_000 ether);
        assertEq(r.remainder, 20_000_000 ether);
        assertEq(r.swarm + r.pool + r.remainder, SUPPLY);

        assertEq(token.balanceOf(distributor), r.swarm, "swarm share arrived short");
        assertEq(token.balanceOf(poolManager), r.pool, "pool share arrived short");
        assertEq(token.balanceOf(requester), r.remainder, "remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "factory kept something back");
        assertEq(token.balanceOf(address(this)), 0, "test contract received tokens");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_neitherTheFactoryCallerNorTheOriginReceivesAnything() public {
        vm.prank(address(this), origin);
        LaunchSimulator.Result memory r = factory.launch(bytes32(uint256(8)), _plan(POOL_BPS));
        assertEq(r.token.balanceOf(origin), 0);
        assertEq(r.token.balanceOf(caller), 0);
        assertEq(r.token.balanceOf(address(this)), 0);
        assertEq(r.token.balanceOf(address(factory)), 0);
    }

    function test_strangerCannotDriveTheLaunchFixture() public {
        vm.prank(caller);
        vm.expectRevert("fixture controller only");
        factory.launch(bytes32(uint256(9)), _plan(POOL_BPS));
    }

    function testFuzz_launchSplitIsExactForAnyPoolShare(uint256 rawPoolBps) public {
        uint256 poolBps = bound(rawPoolBps, 0, 10_000 - factory.SWARM_BPS());
        LaunchSimulator.Result memory r = factory.launch(keccak256(abi.encode(poolBps)), _plan(poolBps));
        assertEq(r.swarm, SUPPLY / 10);
        assertEq(r.pool, SUPPLY * poolBps / 10_000);
        assertEq(r.swarm + r.pool + r.remainder, SUPPLY);
        assertEq(r.token.balanceOf(distributor), r.swarm);
        assertEq(r.token.balanceOf(poolManager), r.pool);
        assertEq(r.token.balanceOf(requester), r.remainder);
        assertEq(r.token.balanceOf(address(factory)), 0);
        assertEq(r.token.totalSupply(), SUPPLY);
    }

    function test_overspendingLaunchRevertsAndDeploysNothing() public {
        bytes32 salt = bytes32(uint256(10));
        address predicted = factory.predict(salt);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        factory.launchOverspending(salt, distributor);
        assertEq(predicted.code.length, 0, "a reverted launch left a token behind");
        // The same salt is still free: a corrected launch lands at the predicted address.
        LaunchSimulator.Result memory r = factory.launch(salt, _plan(POOL_BPS));
        assertEq(address(r.token), predicted);
    }

    function test_overAllocatedPlanRevertsAndDeploysNothing() public {
        bytes32 salt = bytes32(uint256(11));
        address predicted = factory.predict(salt);
        // 90.01% to the pool plus 10% to the swarm exceeds the supply: the remainder underflows.
        LaunchSimulator.Plan memory plan = _plan(10_000 - factory.SWARM_BPS() + 1);
        vm.expectRevert(stdError.arithmeticError);
        factory.launch(salt, plan);
        assertEq(predicted.code.length, 0);
    }

    function test_claimsSplitTheSwarmShareWithoutLoss() public {
        LaunchSimulator.Result memory r = factory.launch(bytes32(uint256(12)), _plan(POOL_BPS));
        POEDBToken token = r.token;
        uint256 claimants = 7;
        uint256 each = r.swarm / claimants;
        uint256 dust = r.swarm - each * claimants;
        assertGt(dust, 0, "pick a claimant count that leaves dust");

        uint256 paid;
        for (uint256 i; i < claimants; ++i) {
            address claimant = makeAddr(string.concat("claimant ", vm.toString(i)));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, each));
            assertEq(token.balanceOf(claimant), each);
            paid += each;
        }
        assertEq(token.balanceOf(distributor), dust);
        assertEq(paid + dust, r.swarm);

        // One more full claim than the distributor holds fails with the exact shortfall.
        address late = makeAddr("late claimant");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, dust, each));
        vm.prank(distributor);
        token.transfer(late, each);
        assertEq(token.balanceOf(late), 0);

        // The dust itself is still claimable, to the last unit.
        vm.prank(distributor);
        assertTrue(token.transfer(late, dust));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(late), dust);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolManagerSellsAndBuysBackExactAmounts() public {
        LaunchSimulator.Result memory r = factory.launch(bytes32(uint256(13)), _plan(POOL_BPS));
        POEDBToken token = r.token;
        address trader = makeAddr("trader");

        uint256 bought = 123_456_789_012_345_678_901;
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, bought));
        assertEq(token.balanceOf(trader), bought);
        assertEq(token.balanceOf(poolManager), r.pool - bought);

        // Selling back through an approval, the way a router or the pool manager settles.
        vm.prank(trader);
        assertTrue(token.approve(poolManager, bought));
        vm.prank(poolManager);
        assertTrue(token.transferFrom(trader, poolManager, bought));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), r.pool);
        assertEq(token.allowance(trader, poolManager), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolManagerCannotMoveMoreThanItHolds() public {
        LaunchSimulator.Result memory r = factory.launch(bytes32(uint256(14)), _plan(POOL_BPS));
        address trader = makeAddr("trader");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poolManager, r.pool, r.pool + 1)
        );
        vm.prank(poolManager);
        r.token.transfer(trader, r.pool + 1);
        assertEq(r.token.balanceOf(poolManager), r.pool);
        assertEq(r.token.balanceOf(trader), 0);
    }

    function test_launchAddressesHaveNoPowerOverHolders() public {
        LaunchSimulator.Result memory r = factory.launch(bytes32(uint256(15)), _plan(POOL_BPS));
        POEDBToken token = r.token;
        address holder = makeAddr("holder");
        vm.prank(requester);
        assertTrue(token.transfer(holder, 5 ether));

        address[3] memory privileged = [address(factory), distributor, poolManager];
        for (uint256 i; i < privileged.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, privileged[i], 0, 1)
            );
            vm.prank(privileged[i]);
            token.transferFrom(holder, privileged[i], 1);
        }
        assertEq(token.balanceOf(holder), 5 ether);
        vm.prank(holder);
        assertTrue(token.transfer(requester, 5 ether));
        assertEq(token.balanceOf(holder), 0);
    }

    function testFuzz_tradesThroughThePoolManagerConserveSupply(uint256 rawOut, uint256 rawBack) public {
        LaunchSimulator.Result memory r = factory.launch(bytes32(uint256(16)), _plan(POOL_BPS));
        POEDBToken token = r.token;
        address trader = makeAddr("trader");
        uint256 out = bound(rawOut, 0, r.pool);
        uint256 back = bound(rawBack, 0, out);

        vm.prank(poolManager);
        assertTrue(token.transfer(trader, out));
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, back));

        assertEq(token.balanceOf(trader), out - back);
        assertEq(token.balanceOf(poolManager), r.pool - out + back);
        assertEq(
            token.balanceOf(trader) + token.balanceOf(poolManager) + token.balanceOf(distributor)
                + token.balanceOf(requester),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
    }
}
