// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {POEDBToken} from "../src/POEDBToken.sol";
import {TokenFactory} from "./helpers/TokenFactory.sol";

/// @dev Exercises ERC-20 movements in the launch, not AMM pricing or Uniswap pool initialization.
contract LaunchTransfersTest is Test {
    function test_launchDistributionClaimsAndPoolTransfersArriveWhole() public {
        address distributor = makeAddr("distributor fixture");
        address poolManager = makeAddr("pool manager fixture");
        address requester = makeAddr("requester fixture");
        address claimant = makeAddr("claimant fixture");
        address trader = makeAddr("trader fixture");
        TokenFactory factory = new TokenFactory();
        POEDBToken token = factory.deploy(keccak256("launch transfer fixture"));

        uint256 supply = 1_000_000_000 * 10 ** 18;
        uint256 swarm = supply * 1_000 / 10_000;
        uint256 pool = supply * 8_800 / 10_000;
        uint256 remainder = supply - swarm - pool;
        assertEq(token.balanceOf(address(factory)), supply);

        factory.distribute(token, distributor, swarm);
        factory.distribute(token, poolManager, pool);
        factory.distribute(token, requester, remainder);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(requester), 20_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);

        uint256 purchase = 123 ether;
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, purchase));
        assertEq(token.balanceOf(trader), purchase);
        assertEq(token.balanceOf(poolManager), pool - purchase);

        vm.prank(trader);
        assertTrue(token.transfer(poolManager, purchase));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.totalSupply(), supply);
    }
}
