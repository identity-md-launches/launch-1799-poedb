// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {POEDBToken} from "../../src/POEDBToken.sol";

/// @dev Test fixture for the direct CREATE2 deployer and subsequent exact-amount distributions.
contract TokenFactory {
    address private immutable controller = msg.sender;

    function deploy(bytes32 salt) external returns (POEDBToken) {
        return new POEDBToken{salt: salt}();
    }

    function distribute(POEDBToken token, address recipient, uint256 amount) external {
        require(msg.sender == controller, "fixture controller only");
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

/// @dev A receiver that cannot accept callbacks; ERC-20 transfers must still succeed.
contract RejectingReceiver {
    fallback() external {
        revert("no callbacks");
    }
}
