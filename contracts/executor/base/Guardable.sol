// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.20;

import {SelfAuthorized} from "./SelfAuthorized.sol";
import {IGuard} from "../interfaces/IGuard.sol";
import {IGuardable} from "../interfaces/IGuardable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

abstract contract BaseGuard is IGuard, IERC165 {

    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return
            interfaceId == type(IGuard).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

}

/**
 * @title Guardable - Zodiac implementation to make an Avatar guardable
 *
 * @notice Uses EIP-7201 namespacing to store the guard
 *
 * @author Ben Jett
 */
contract Guardable is SelfAuthorized, IGuardable, ERC165Upgradeable {

    /**
     * @dev ERC-7201 storage of guard address.
     *
     * @custom:storage-location erc7201:Guardable.Guard
     */
    struct Guard {
        address guard;
    }

    // keccak256(abi.encode(uint256(keccak256("Guardable.Guard")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GUARD_STORAGE = 0xb9d3a8d837bd64eb8b3d5413c224f88c19240bdb6b341bdf998410e40fcd3a00;

    event ChangedGuard(address guard);

    /// `guard` does not implement IERC165.
    error NotIERC165Compliant(address guard);

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IGuardable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * Set a guard that checks transactions before execution.
     * @param guard The address of the guard to be used or the 0 address to disable the guard.
     */
    function setGuard(address guard) external onlySelf {
        _setGuard(guard);
    }

    function _setGuard(address guard) internal {
        if (guard != address(0)) {
            if (!ERC165Checker.supportsInterface(guard, type(IGuard).interfaceId)) {
                revert NotIERC165Compliant(guard);
            }
        }
        Guard storage $;
        assembly {
            $.slot := GUARD_STORAGE
        }
        $.guard = guard;
        emit ChangedGuard(guard);
    }

    /**
     * Returns the current address of the guard contract (if implemented).
     * @return guard The address of the guard contract.
     */
    function getGuard() public view returns (address guard) {
        Guard storage $;
        assembly {
            $.slot := GUARD_STORAGE
        }
        guard = $.guard;
    }

}