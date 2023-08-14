// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.4;

import "../../token/extensions/VotesProvisioner.sol";
import "../Executor.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Treasurer is Executor {

    VotesProvisioner internal immutable _votes;
    IERC20 internal immutable _baseAsset;

    // The previously measured DAO balance (minus any _stashedBalance), for tracking changes to the balance amount
    uint256 internal _balance;
    // The total balance of the base asset that is allocated to Distributions, BalanceShares, etc.
    uint256 internal _stashedBalance;

    constructor(
        VotesProvisioner votes_
    ) {
        _votes = votes_;
        _baseAsset = IERC20(votes_.baseAsset());
    }

    function votes() public view returns(address) {
        return address(_votes);
    }

    modifier onlyVotes() {
        _onlyVotes();
        _;
    }

    error OnlyVotes();
    function _onlyVotes() private view {
        if (msg.sender != address(_votes)) revert OnlyVotes();
    }

    function baseAsset() public view returns (address) {
        return address(_baseAsset);
    }

    /**
     * @notice Returns the current DAO balance of the base asset in the treasury.
     */
    function treasuryBalance() external view returns (uint256) {
        return _treasuryBalance();
    }

    /**
     * @dev An internal function that must be overridden to properly return the DAO treasury balance.
     */
    function _treasuryBalance() internal view virtual returns (uint256) {
        return _baseAssetBalance() - _stashedBalance;
    }

    /**
     * @dev An internal function that must be overridden to properly return the raw base asset balance.
     */
    function _baseAssetBalance() internal view virtual returns (uint256);

    error FailedToTransferBaseAsset(address to, uint256 amount);
    /**
     * @dev Internal function to transfer an amount of the base asset to the specified address.
     */
    function _safeTransferBaseAsset(address to, uint256 amount) internal virtual;

    /**
     * @dev Internal function to transfer an amount of the base asset from the stashed balance.
     */
    function _transferStashedBaseAsset(address to, uint256 amount) internal virtual {
        _stashedBalance -= amount;
        _safeTransferBaseAsset(to, amount);
    }

    /**
     * @notice Registers a deposit on the Treasurer. Only callable by the votes contract.
     * @param depositAmount The amount being deposited.
     */
    function registerDeposit(uint256 depositAmount) public payable virtual onlyVotes {
        _registerDeposit(depositAmount);
    }

    error InvalidDepositAmount();
    /// @dev Can override and call super._registerDeposit for additional checks/functionality depending on baseAsset used
    function _registerDeposit(uint256 depositAmount) internal virtual {
        if (depositAmount == 0) revert InvalidDepositAmount();
    }

    /**
     * @notice Processes a withdrawal from the Treasurer to the withdrawing member. Only callable by the votes contract.
     * @param receiver The address to send the base asset to.
     * @param withdrawAmount The amount of base asset to send.
     */
    function processWithdrawal(address receiver, uint256 withdrawAmount) public virtual onlyVotes {
        _processWithdrawal(receiver, withdrawAmount);
    }

    /// @dev Must override to implement the actual transfer functionality depending on what baseAsset is used
    function _processWithdrawal(address receiver, uint256 withdrawAmount) internal virtual {
        _safeTransferBaseAsset(receiver, withdrawAmount);
    }

}