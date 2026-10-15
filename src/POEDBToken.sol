// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title poedb (POEDB)
/// @notice A fixed supply of one billion tokens, with 18 decimals, minted once to the deployer.
/// @dev The direct constructor caller receives the supply, including when a factory deploys this contract.
/// There are no administrative roles, transfer fees, external mint/burn functions, or upgrade mechanisms.
contract POEDBToken is ERC20 {
    /// @notice Total supply in the token's smallest unit (1 POEDB = 10**18 units).
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("poedb", "POEDB") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
