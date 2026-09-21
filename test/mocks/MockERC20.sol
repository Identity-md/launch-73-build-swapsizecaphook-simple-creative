// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Test-only ERC-20 that mints a fixed supply to its deployer. Not part of the deliverable.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, supply);
    }
}
