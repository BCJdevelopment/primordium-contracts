// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Treasurer} from "./base/Treasurer.sol";
import {AuthorizeInitializer} from "contracts/utils/AuthorizeInitializer.sol";

/**
 * @title Executor - The deployable executor contract.
 *
 * @author Ben Jett - @BCJdevelopment
 */
abstract contract Executor is Initializable, AuthorizeInitializer, Treasurer {

    function initializeExecutor(
        bytes calldata params
    ) external initializer authorizeInitializer {

    }

}
