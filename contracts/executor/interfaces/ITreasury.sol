// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.20;

import {IVotesProvisioner} from "contracts/shares/interfaces/IVotesProvisioner.sol";

/**
 * @title ITreasury - The interface required for the token contract to facilitate deposits and withdrawals.
 * @author Ben Jett - @BCJdevelopment
 */
interface ITreasury {

    function treasuryBalance() external view returns (uint256);

    function governanceInitialized(address asset, uint256 totalDeposits) external;

    function registerDeposit(
        address asset,
        uint256 depositAmount,
        IVotesProvisioner.ProvisionMode provisionMode
    ) external payable;

    function processWithdrawal(address asset, address receiver, uint256 withdrawAmount) external payable;



}