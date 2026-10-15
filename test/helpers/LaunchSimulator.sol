// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {POEDBToken} from "../../src/POEDBToken.sol";

/// @dev Mirrors what the launch factory does in one transaction: deploy the token with CREATE2 and,
/// in the same call, split the supply the constructor minted to it among the distributor, the pool
/// manager and the requester. Everything happens in one call so a test sees exactly what one
/// `launchCustom` transaction would see. Only the deploying test may drive it.
contract LaunchSimulator {
    uint256 public constant SWARM_BPS = 1_000;

    address private immutable controller = msg.sender;

    struct Plan {
        address distributor;
        address poolManager;
        address requester;
        uint256 poolBps;
    }

    struct Result {
        POEDBToken token;
        uint256 supply;
        uint256 swarm;
        uint256 pool;
        uint256 remainder;
    }

    modifier onlyController() {
        require(msg.sender == controller, "fixture controller only");
        _;
    }

    /// @notice Deploys and distributes in one call. Reverts, and therefore deploys nothing, if any leg fails.
    function launch(bytes32 salt, Plan calldata plan) external onlyController returns (Result memory result) {
        result.token = new POEDBToken{salt: salt}();
        result.supply = result.token.totalSupply();
        require(result.token.balanceOf(address(this)) == result.supply, "constructor did not mint to the factory");
        result.swarm = result.supply * SWARM_BPS / 10_000;
        result.pool = result.supply * plan.poolBps / 10_000;
        result.remainder = result.supply - result.swarm - result.pool;
        require(result.token.transfer(plan.distributor, result.swarm), "swarm transfer returned false");
        require(result.token.transfer(plan.poolManager, result.pool), "pool transfer returned false");
        require(result.token.transfer(plan.requester, result.remainder), "remainder transfer returned false");
    }

    /// @notice Deploys and then tries to forward one unit more than the constructor minted.
    function launchOverspending(bytes32 salt, address to) external onlyController returns (POEDBToken token) {
        token = new POEDBToken{salt: salt}();
        token.transfer(to, token.totalSupply() + 1);
    }

    /// @notice Deploys the raw creation code with `msg.value` attached, returning the zero address on failure.
    function deployWithValue() external payable onlyController returns (address deployed) {
        bytes memory code = type(POEDBToken).creationCode;
        uint256 value = msg.value;
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }

    function predict(bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(POEDBToken).creationCode))
                    )
                )
            )
        );
    }

    receive() external payable {}
}
