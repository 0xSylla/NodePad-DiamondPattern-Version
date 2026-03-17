// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SolidStateDiamond} from "lib/solidstate-solidity/contracts/proxy/diamond/SolidStateDiamond.sol";

/**
 * @title  Nodepad
 * @notice Nodepad Proxy Cobtract
 * @dev    This is a Diamond Contract following EIP-2535.
 *         To view its ABI and interact with functions,
 *         use an EIP-2535 compatible explorer.
 */
contract NodepadDiamondProxy is SolidStateDiamond {}
