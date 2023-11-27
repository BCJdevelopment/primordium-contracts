// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasisPoints} from "contracts/libraries/BasisPoints.sol";
import {IArrayLengthErrors} from "contracts/interfaces/IArrayLengthErrors.sol";

/**
 * @title A utility library for tracking multiple account shares in BPS of ETH/ERC20 assets
 *
 * @author Ben Jett - @BCJdevelopment
 *
 * @dev This library operates on the principal that the utilizing contract will act as a holding contract for all of the
 * assets, and will use this library as the internal accounting to allow each account share to withdraw their
 * accumulated claim to shared assets at any point in time.
 *
 * The main point of this library's accounting is to optimize gas costs into a single batch withdrawal for each account
 * share recipient while significantly reducing the gas costs for a protocol's users.
 *
 * A hypothetical example: 4 accounts need to each receive 5% of the deposit amount for an on-chain mint. Rather than
 * paying huge gas costs to send 5% of the deposit amount to 4 different accounts every time asset(s) are minted, the
 * minting contract would send 20% of the deposit amount to this contract in each mint transaction. Then, each
 * individual account recipient can process a batch withdrawal of their claim to the accumulated share funds at any
 * point in time.
 *
 * This also enables adding additional withdrawal permissions in the utilizing contract to give account share owners the
 * ability to grant permissions and/or use signed messages to process asset withdrawals in batches.
 */
library BalanceShareUtils {
    using BasisPoints for uint256;

    struct BalanceShare {
        // New balance sum created every time totalBps changes, or when sum overflow occurs
        // Mapping, not array, to avoid storage collisions
        uint256 balanceSumCheckpointIndex;
        mapping(uint256 balanceSumIndex => BalanceSumCheckpoint) balanceSumCheckpoints;

        mapping(address => AccountShare) accounts;
    }

    struct BalanceSumCheckpoint {
        uint256 totalBps; // Tracks the totalBps among all account shares for this balance sum checkpoint
        mapping(address asset => BalanceSum) assetBalanceSum;
    }

    /**
     * @dev Storing asset remainders in the BalanceSum struct will not carry asset remainders over to a new
     * BalanceSumCheckpoint, but packing the storage with the asset balanceSum avoids writing to an extra storage slot
     * when a new balance is processed and added to the balance sum. We optimize for the gas usage here, as new
     * checkpoints will only be written when the total BPS changes or an asset overflows, both of which are not likely
     * to be as common of events as the actual balance processing itself. And the point of this library is to offload
     * gas costs for balance shares from the users to the account recipients.
     */
    struct BalanceSum {
        uint48 remainder;
        uint208 balanceSum;
    }

    struct AccountShare {
        // Store each account share period for the account, sequentially
        // Mapping, not array, to avoid storage collisions
        uint256 periodIndex;
        mapping(uint256 checkpointIndex => AccountSharePeriod) periods;
    }

    struct AccountSharePeriod {
        uint16 bps; // The account's BPS share this period
        uint48 startBalanceSumIndex; // Balance sum index where this account share period begins
        uint48 endBalanceSumIndex; // Balance sum index where this account share period ends, or MAX_INDEX when active
        uint48 initializedAt; // Block number this checkpoint was initialized
        uint48 removeableAt; // Timestamp in seconds at which the account share can be removed
        mapping(address asset => AccountCurrentBalanceSum) currentAssetBalanceSum;
    }

    struct AccountCurrentBalanceSum {
        uint48 currentBalanceSumIndex; // The current asset balance check index for the account
        uint208 previousBalanceSumAtWithdrawal; // The asset balance when it was last withdrawn by the account
    }

    // HELPER CONSTANTS
    uint256 constant private MAX_INDEX = type(uint48).max;
    uint256 constant private MAX_BALANCE_SUM = type(uint208).max;

    error InvalidAddress(address account);
    error AccountSharePeriodAlreadyExists(address account, uint256 period);
    error AccountNotActive(address account);
    error AccountShareStillLocked(address account);
    error Unauthorized();
    error AccountWithdrawalsFinished();
    error ZeroValueNotAllowed();
    error CannotDecreaseAccountBPSToZero();
    error UpdateExceedsMaxBps(uint256 newTotalBps, uint256 maxBps);

    /**
     * @dev Adds the provided account shares to the balance share. Must provide the account addresses, the basis points
     * share per account, and a timestamp for when the account share can be removed. Reverts for accounts that already
     * have active BPS shares.
     */
    function createAccountShares(
        BalanceShare storage _self,
        address[] memory accounts,
        uint256[] memory basisPoints,
        uint256[] memory removeableAts
    ) internal {
        if (accounts.length == 0) revert IArrayLengthErrors.MissingArrayItems();
        if (
            accounts.length != basisPoints.length ||
            accounts.length != removeableAts.length
        ) revert IArrayLengthErrors.MismatchingArrayLengths();

        uint48 _balanceSumCheckpointIndex = uint48(_self.balanceSumCheckpointIndex);
        uint256 _totalBps = _self.balanceSumCheckpoints[_balanceSumCheckpointIndex].totalBps;

        // Increment to new BalanceSumCheckpoint if the totalBps is already greater than zero
        if (_totalBps > 0) {
            _balanceSumCheckpointIndex++;
        }

        // Loop through accounts and track BPS changes
        uint256 increaseTotalBpsBy;

        for (uint256 i = 0; i < accounts.length;) {
            // No zero addresses
            if (accounts[0] == address(0)) {
                revert InvalidAddress(accounts[0]);
            }

            // Revert if the account share already has an active bps share
            AccountShare storage _accountShare = _self.accounts[accounts[i]];
            uint256 _accountSharePeriodIndex = _accountShare.periodIndex;
            AccountSharePeriod storage _accountSharePeriod = _accountShare.periods[_accountSharePeriodIndex];
            if (_accountSharePeriod.bps > 0) {
                revert AccountSharePeriodAlreadyExists(accounts[i], _accountSharePeriodIndex);
            }

            // We don't verify the BPS amount here, because total will be verified when updating the bps
            increaseTotalBpsBy += basisPoints[i];

            // Initialize the new AccountSharePeriod (overwriting period with BPS of zero)
            _accountSharePeriod.bps = uint16(basisPoints[i]);
            _accountSharePeriod.startBalanceSumIndex = _balanceSumCheckpointIndex;
            _accountSharePeriod.endBalanceSumIndex = uint48(MAX_INDEX);
            _accountSharePeriod.initializedAt = uint48(block.number);
            _accountSharePeriod.removeableAt = SafeCast.toUint48(removeableAts[i]);

            unchecked { ++i; }
        }

        // Update the totalBps (which checks for total basis points value that exceeds the max)
        _updateTotalBps(_self, _balanceSumCheckpointIndex, _totalBps + increaseTotalBpsBy);

    }

    /**
     * @dev Helper method for updating the totalBps for a BalanceSumCheckpoint. Reverts if the newTotalBps exceeds the
     * maximum.
     */
    function _updateTotalBps(
        BalanceShare storage _self,
        uint256 balanceSumCheckpointIndex,
        uint256 newTotalBps
    ) private {
        if (newTotalBps > BasisPoints.MAX_BPS) {
            revert UpdateExceedsMaxBps(newTotalBps, BasisPoints.MAX_BPS);
        }

        _self.balanceSumCheckpoints[balanceSumCheckpointIndex].totalBps = newTotalBps;
    }

    // /**
    //  * @dev Removes the specified accounts from receiving further shares. Does not process withdrawals. The receivers
    //  * will still have access to withdraw their balances that were accumulated prior to removal.
    //  *
    //  * Requires that the block.timestamp is greater than the account's "removableAt" parameter, or else throws an error.
    //  *
    //  * It is recommended that the host contract process current balance shares before removing accounts.
    //  */
    // function removeAccountShares(
    //     BalanceShare storage _self,
    //     address[] calldata accounts
    // ) internal {
    //     uint256 subFromTotalBps;
    //     uint256 latestBalanceCheckIndex = _self._balanceChecks.length - 1;
    //     for (uint256 i = 0; i < accounts.length;) {
    //         unchecked {
    //             // Can be unchecked, bps was checked when the account share was added
    //             subFromTotalBps += _destroyAccountShare(_self, accounts[i], latestBalanceCheckIndex);
    //             ++i;
    //         }
    //     }

    //     // Update the totalBps
    //     BalanceCheck memory latestBalanceCheck = _self._balanceChecks[latestBalanceCheckIndex];
    //     uint256 newTotalBps = latestBalanceCheck.totalBps - subFromTotalBps;
    //     _updateTotalBps(_self, latestBalanceCheck.balance, latestBalanceCheckIndex, newTotalBps);
    // }

    // /**
    //  * @dev A helper function for allowing an AccountShare recipient to remove their own account.
    //  *
    //  * (_destroyAccountShare allows the msg.sender to destroy the account share before the removableAt timestamp)
    //  */
    // function removeAccountShareSelf(
    //     BalanceShare storage _self
    // ) internal {
    //     uint256 latestBalanceCheckIndex = _self._balanceChecks.length - 1;
    //     BalanceCheck memory latestBalanceCheck = _self._balanceChecks[latestBalanceCheckIndex];
    //     uint256 newTotalBps =
    //         latestBalanceCheck.totalBps - _destroyAccountShare(_self, msg.sender, latestBalanceCheckIndex);
    //     _updateTotalBps(_self, latestBalanceCheck.balance, latestBalanceCheckIndex, newTotalBps);
    // }

    // /**
    //  * @dev Method to add to the total pool of balance available to the account shares, at the rate of:
    //  * balanceIncreasedBy * totalBps / 10_000
    //  * @param balanceIncreasedBy A uint256 representing how much the core balance increased by, which will be multiplied
    //  * by the totalBps for all active balance shares to be made available to those accounts.
    //  * @return balanceAddedToShares Returns the amount added to the balance shares, which should be accounted for in the
    //  * host contract.
    //  */
    // function processBalance(
    //     BalanceShare storage _self,
    //     uint256 balanceIncreasedBy
    // ) internal returns (uint256 balanceAddedToShares) {
    //     uint256 length = _self._balanceChecks.length;
    //     // Only continue if the length is greater than zero, otherwise returns zero by default
    //     if (length > 0) {
    //         BalanceCheck storage latestBalanceCheck = _self._balanceChecks[length - 1];
    //         uint256 currentTotalBps = latestBalanceCheck.totalBps;
    //         if (currentTotalBps > 0) {
    //             balanceAddedToShares = _processBalance(_self, currentTotalBps, balanceIncreasedBy);
    //             _addBalance(_self, latestBalanceCheck, balanceAddedToShares);
    //         }
    //     }
    // }

    // /**
    //  * @dev A function to directly add a given amount to the balance shares. This amount should be accounted for in the
    //  * host contract.
    //  */
    // function addBalanceToShares(
    //     BalanceShare storage _self,
    //     uint256 amount
    // ) internal {
    //     uint256 length = _self._balanceChecks.length;
    //     if (length > 0) {
    //         BalanceCheck storage latestBalanceCheck = _self._balanceChecks[length - 1];
    //         _addBalance(_self, latestBalanceCheck, amount);
    //     }
    // }

    // /**
    //  * @dev Processes an account withdrawal, calculating the balance amount that should be paid out to the account. As a
    //  * result of this function, the balance amount to be paid out is marked as withdrawn for this account. The host
    //  * contract is responsible for ensuring this balance is paid out to the account as part of the transaction.
    //  *
    //  * Can only be processed if msg.sender is the account itself, or if msg.sender is approved, or if the account has
    //  * approved anyone (address(0) is approved).
    //  *
    //  * @return balanceToBePaid This is the balance that is marked as paid out for the account. The host contract should
    //  * pay this balance to the account as part of the withdrawal transaction.
    //  */
    // function processAccountWithdrawal(
    //     BalanceShare storage _self,
    //     address account
    // ) internal returns (uint256) {

    //     // Authorize the msg.sender
    //     if (
    //         msg.sender != account &&
    //         !_self._accountWithdrawalApprovals[account][msg.sender] &&
    //         !_self._accountWithdrawalApprovals[account][address(0)]
    //     ) revert Unauthorized();

    //     AccountShare storage accountShare = _self._accounts[account];
    //     (
    //         uint256 balanceToBePaid,
    //         uint256 lastBalanceCheckIndex,
    //         uint256 lastBalancePulled
    //     ) = _calculateAccountBalance(
    //         _self,
    //         accountShare,
    //         true // Revert if the account is already completed their withdrawals, save the gas
    //     );

    //     // Save the account updates to storage
    //     accountShare.lastBalanceCheckIndex = uint40(lastBalanceCheckIndex);
    //     accountShare.lastBalancePulled = lastBalancePulled;
    //     accountShare.lastWithdrawnAt = uint40(block.timestamp);

    //     return balanceToBePaid;
    // }

    // /**
    //  * @dev Increases the account BPS, updating the total BPS and returning the new account BPS.
    //  * @return accountBps Returns the new account BPS.
    //  */
    // function increaseAccountBps(
    //     BalanceShare storage _self,
    //     address account,
    //     uint256 increaseBy
    // ) internal returns (uint256) {
    //     if (increaseBy == 0) revert ZeroValueNotAllowed();
    //     AccountShare storage accountShare = _self._accounts[account];
    //     // Account must not have finished withdrawals (this also ensures that the account has been initialized)
    //     if (_accountHasFinishedWithdrawals(accountShare)) revert AccountNotActive(account);
    //     uint256 newAccountBps = accountShare.bps + increaseBy;
    //     accountShare.bps = SafeCast.toUint16(newAccountBps);

    //     // Also update the totalBps
    //     uint256 latestBalanceCheckIndex = _self._balanceChecks.length - 1;
    //     BalanceCheck memory latestBalanceCheck = _self._balanceChecks[latestBalanceCheckIndex];
    //     _updateTotalBps(
    //         _self,
    //         latestBalanceCheck.balance,
    //         latestBalanceCheckIndex,
    //         latestBalanceCheck.totalBps + increaseBy
    //     );
    //     return newAccountBps;
    // }

    // /**
    //  * @dev Function to decrease the basis points share for an account. Defaults to not allowing the bps decrease if the
    //  * current timestamp is earlier than the account's "removableAt" timestamp.
    //  */
    // function decreaseAccountBps(
    //     BalanceShare storage _self,
    //     address account,
    //     uint256 decreaseBy
    // ) internal returns (uint256) {
    //     if (decreaseBy == 0) revert ZeroValueNotAllowed();
    //     AccountShare storage accountShare = _self._accounts[account];
    //     // Account must not have finished withdrawals (this also ensures that the account has been initialized)
    //     if (_accountHasFinishedWithdrawals(accountShare)) revert AccountNotActive(account);
    //     (
    //         uint256 bps,
    //         uint256 removableAt
    //     ) = (
    //         accountShare.bps,
    //         accountShare.removableAt
    //     );
    //     // Cannot decrease to zero (should call remove account share in that case)
    //     if (decreaseBy >= bps) revert CannotDecreaseAccountBPSToZero();
    //     // The current timestamp must be greater than the removableAt timestamp (unless explicitly skipped)
    //     if (block.timestamp < removableAt && msg.sender != account) revert AccountShareStillLocked(account);

    //     // Update the account bps
    //     uint256 newAccountBps = bps - decreaseBy;
    //     accountShare.bps = uint16(newAccountBps);

    //     // Update the totalBps too
    //     uint256 latestBalanceCheckIndex = _self._balanceChecks.length - 1;
    //     BalanceCheck memory latestBalanceCheck = _self._balanceChecks[latestBalanceCheckIndex];
    //     _updateTotalBps(
    //         _self,
    //         latestBalanceCheck.balance,
    //         latestBalanceCheckIndex,
    //         latestBalanceCheck.totalBps - decreaseBy
    //     );

    //     return newAccountBps;
    // }

    // /**
    //  * @dev Helper method to update the "removableAt" timestamp for an account. Can only decrease if msg.sender is the
    //  * account, otherwise can only increase.
    //  */
    // function updateAccountRemovableAt(
    //     BalanceShare storage _self,
    //     address account,
    //     uint256 newRemovableAt
    // ) internal {
    //     uint256 currentRemovableAt = _self._accounts[account].removableAt;
    //     // If msg.sender, then can decrease, otherwise can only increase
    //     // NOTE: This also ensures uninitiated accounts don't change anything as well. If msg.sender is the account,
    //     // then currentRemovableAt will be zero, which will throw an error
    //     if (
    //         msg.sender == account ?
    //         newRemovableAt >= currentRemovableAt :
    //         newRemovableAt <= currentRemovableAt
    //     ) revert Unauthorized();
    //     _self._accounts[account].removableAt = SafeCast.toUint40(newRemovableAt);
    // }

    // /**
    //  * @dev Approve the provided list of addresses to initiate withdrawal on the account. Approve address(0) to allow
    //  * anyone.
    //  */
    // function approveAddressesForWithdrawal(
    //     BalanceShare storage _self,
    //     address account,
    //     address[] calldata approvedAddresses
    // ) internal {
    //     for (uint256 i = 0; i < approvedAddresses.length;) {
    //         _self._accountWithdrawalApprovals[account][approvedAddresses[i]] = true;
    //         unchecked { ++i; }
    //     }
    // }

    // /**
    //  * @dev Unapprove the provided list of addresses for initiating withdrawals on the account.
    //  */
    // function unapproveAddressesForWithdrawal(
    //     BalanceShare storage _self,
    //     address account,
    //     address[] calldata unapprovedAddresses
    // ) internal {
    //     for (uint256 i = 0; i < unapprovedAddresses.length;) {
    //         _self._accountWithdrawalApprovals[account][unapprovedAddresses[i]] = false;
    //         unchecked { ++i; }
    //     }
    // }

    // /**
    //  * @dev A function for changing the address that an account receives its shares to. This is only callable by the
    //  * account owner. A list of approved addresses for withdrawal can be provided.
    //  *
    //  * Note that by default, if the address(0) was approved (meaning anyone can process a withdrawal to the account),
    //  * then address(0) will be approved for the new account address as well.
    //  *
    //  * @param account The address for the current account share (which must be msg.sender)
    //  * @param newAccount The new address to copy the account share over to.
    //  * @param approvedAddresses A list of addresses to be approved for processing withdrawals to the account receiver.
    //  */
    // function changeAccountAddress(
    //     BalanceShare storage _self,
    //     address account,
    //     address newAccount,
    //     address[] calldata approvedAddresses
    // ) internal {
    //     if (msg.sender != account) revert Unauthorized();
    //     if (newAccount == address(0)) revert InvalidAddress(newAccount);
    //     // Copy it over
    //     _self._accounts[newAccount] = _self._accounts[account];
    //     // Zero out the old account
    //     delete _self._accounts[account];

    //     // Approve addresses
    //     approveAddressesForWithdrawal(_self, newAccount, approvedAddresses);

    //     if (_self._accountWithdrawalApprovals[account][address(0)]) {
    //         _self._accountWithdrawalApprovals[newAccount][address(0)] = true;
    //     }
    // }

    // /**
    //  * @dev The total basis points sum for all currently active account shares.
    //  * @return totalBps An integer representing the total basis points sum. 1 basis point = 0.01%
    //  */
    // function totalBps(
    //     BalanceShare storage _self
    // ) internal view returns (uint256) {
    //     uint256 length = _self._balanceChecks.length;
    //     return length > 0 ?
    //         _self._balanceChecks[length - 1].totalBps :
    //         0;
    // }

    // /**
    //  * @dev A function to calculate the balance to be added to the shares provided the amount the balance increased by
    //  * and the current total BPS. Returns both the calculated balance to be added to the balance shares, as well as the
    //  * remainder (useful for storing for next time).
    //  * @param balanceIncreasedBy A uint256 representing how much the core balance increased by, which will be multiplied
    //  * by the totalBps for all active balance shares to be made available to those accounts.
    //  * @return balanceToAddToShares The calculated balance to add the shares
    //  */
    // function calculateBalanceToAddToShares(
    //     BalanceShare storage _self,
    //     uint256 balanceIncreasedBy
    // ) internal view returns (uint256 balanceToAddToShares) {
    //     uint256 currentTotalBps = totalBps(_self);
    //     if (currentTotalBps > 0) {
    //         (balanceToAddToShares,) = _calculateBalanceShare(_self, balanceIncreasedBy, currentTotalBps);
    //     }
    // }

    // /**
    //  * @dev Returns the current withdrawable balance for an account share.
    //  * @return balanceAvailable The balance available for withdraw from this account.
    //  */
    // function accountBalance(
    //     BalanceShare storage _self,
    //     address account
    // ) internal view returns (uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     (uint256 balanceAvailable,,) = _calculateAccountBalance(
    //         _self,
    //         accountShare,
    //         false // Show the zero balance
    //     );
    //     return balanceAvailable;
    // }

    // /**
    //  * @dev A helper function to predict the account balance with an additional "balanceIncreasedBy" parameter (assuming
    //  * the state has not been updated to match yet).
    //  * @return accountBalance Returns the predicted account balance.
    //  */
    // function predictedAccountBalance(
    //     BalanceShare storage _self,
    //     address account,
    //     uint256 balanceIncreasedBy
    // ) internal view returns (uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     (uint256 balanceAvailable,,) = _calculateAccountBalance(
    //         _self,
    //         accountShare,
    //         false
    //     );
    //     (uint256 addedTotalBalance,) = _calculateBalanceShare(
    //         _self,
    //         balanceIncreasedBy,
    //         accountShare.bps
    //     );
    //     return balanceAvailable + addedTotalBalance.bps(accountShare.bps);
    // }

    // /**
    //  * @dev Returns a bool indicating whether or not the address is approved for withdrawal on the specified account.
    //  */
    // function isAddressApprovedForWithdrawal(
    //     BalanceShare storage _self,
    //     address account,
    //     address address_
    // ) internal view returns (bool) {
    //     return _self._accountWithdrawalApprovals[account][address_];
    // }

    // /**
    //  * @dev Returns the following details (in order) for the specified account:
    //  * - bps
    //  * - createdAt
    //  * - removableAt
    //  * - lastWithdrawnAt
    //  */
    // function accountDetails(
    //     BalanceShare storage _self,
    //     address account
    // ) internal view returns (uint256, uint256, uint256, uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     return (
    //         accountShare.bps,
    //         accountShare.createdAt,
    //         accountShare.removableAt,
    //         accountShare.lastWithdrawnAt
    //     );
    // }

    // /**
    //  * @dev An account is considered to be finished with withdrawals when the account's "lastBalanceCheckIndex" is
    //  * greater than the account's "endIndex".
    //  *
    //  * Returns true if the account has not been initialized with any shares yet.
    //  */
    // function accountHasFinishedWithdrawals(
    //     BalanceShare storage _self,
    //     address account
    // ) internal view returns (bool) {
    //     return _accountHasFinishedWithdrawals(_self._accounts[account]);
    // }

    // function _destroyAccountShare(
    //     BalanceShare storage _self,
    //     address account,
    //     uint256 latestBalanceCheckIndex
    // ) private returns (uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     uint256 bps = accountShare.bps;
    //     uint256 endIndex = accountShare.endIndex;
    //     uint256 removableAt = accountShare.removableAt;
    //     // The account share must be active to be removed
    //     if (endIndex != MAX_INDEX) revert AccountNotActive(account);
    //     // The current timestamp must be greater than the removableAt timestamp (unless the msg.sender owns the account)
    //     if (block.timestamp < removableAt && msg.sender != account) revert AccountShareStillLocked(account);

    //     // Set the bps to 0, and the endIndex to be the current balance share index
    //     accountShare.bps = 0;
    //     accountShare.endIndex = uint40(latestBalanceCheckIndex);
    //     return bps;
    // }

    // /**
    //  * @dev Private function that takes the balanceIncreasedBy, adds the previous _balanceRemainder, and returns the
    //  * balanceToAddToShares, updating the stored _balanceRemainder in the process.
    //  */
    // function _processBalance(
    //     BalanceShare storage _self,
    //     uint256 currentTotalBps,
    //     uint256 balanceIncreasedBy
    // ) private returns (uint256) {
    //     (
    //         uint256 balanceToAddToShares,
    //         uint256 newBalanceRemainder
    //     ) = _calculateBalanceShare(_self, balanceIncreasedBy, currentTotalBps);
    //     // Update with the new remainder
    //     _self._balanceRemainder = SafeCast.toUint16(newBalanceRemainder);
    //     return balanceToAddToShares;
    // }

    // /**
    //  * @dev Private function that returns the balanceToAddToShares, and the mulmod remainder of the operation.
    //  * NOTE: This function adds the previous _balanceRemainder to the balanceIncreasedBy parameter before running the
    //  * calculations.
    //  */
    // function _calculateBalanceShare(
    //     BalanceShare storage _self,
    //     uint256 balanceIncreasedBy,
    //     uint256 bps
    // ) private view returns (uint256, uint256) {
    //     balanceIncreasedBy += _self._balanceRemainder; // Adds the previous remainder into the calculation
    //     return (
    //         balanceIncreasedBy.bps(bps),
    //         balanceIncreasedBy.bpsMulmod(bps)
    //     );
    // }

    // /**
    //  * @dev Private function, adds the provided balance amount to the shared balances.
    //  */
    // function _addBalance(
    //     BalanceShare storage _self,
    //     BalanceCheck storage latestBalanceCheck,
    //     uint256 amount
    // ) private {
    //     if (amount > 0) {
    //         // Unchecked because manual checks ensure no overflow/underflow
    //         unchecked {
    //             // Start with a reference to the current balance
    //             uint256 currentBalance = latestBalanceCheck.balance;
    //             // Loop until break
    //             while (true) {
    //                 // Can only increase current balanceCheck up to the MAX_CHECK_BALANCE_AMOUNT
    //                 uint256 balanceIncrease = Math.min(amount, MAX_CHECK_BALANCE_AMOUNT - currentBalance);
    //                 latestBalanceCheck.balance = uint240(currentBalance + balanceIncrease);
    //                 amount -= balanceIncrease;
    //                 // If there is still more balance remaining, push a new balanceCheck and zero out the currentBalance
    //                 if (amount > 0) {
    //                     _self._balanceChecks.push(BalanceCheck(latestBalanceCheck.totalBps, 0));
    //                     latestBalanceCheck = _self._balanceChecks[_self._balanceChecks.length - 1];
    //                     currentBalance = 0;
    //                 } else {
    //                     break; // Can complete once amount remaining is zero
    //                 }
    //             }
    //         }
    //     }
    // }

    // /**
    //  * @dev Private function to calculate the current balance owed to the AccountShare.
    //  * @return accountBalanceOwed The balance owed to the account share.
    //  * @return lastBalanceCheckIndex The resulting lastBalanceCheckIndex for the account.
    //  * @return lastBalancePulled The resulting lastBalancePulled for the account.
    //  */
    // function _calculateAccountBalance(
    //     BalanceShare storage _self,
    //     AccountShare storage accountShare,
    //     bool revertOnWithdrawalsFinished
    // ) private view returns(
    //     uint256 accountBalanceOwed,
    //     uint256,
    //     uint256
    // ) {
    //     (
    //         uint256 bps,
    //         uint256 createdAt,
    //         uint256 endIndex,
    //         uint256 lastBalanceCheckIndex,
    //         uint256 lastBalancePulled
    //     ) = (
    //         accountShare.bps,
    //         accountShare.createdAt,
    //         accountShare.endIndex,
    //         accountShare.lastBalanceCheckIndex,
    //         accountShare.lastBalancePulled
    //     );

    //     // If account is not active or is already finished with withdrawals, return zero
    //     if (_accountHasFinishedWithdrawals(createdAt, lastBalanceCheckIndex, endIndex)) {
    //         if (revertOnWithdrawalsFinished) {
    //             revert AccountWithdrawalsFinished();
    //         }
    //         return (accountBalanceOwed, lastBalanceCheckIndex, lastBalancePulled);
    //     }

    //     uint256 latestBalanceCheckIndex = _self._balanceChecks.length - 1;

    //     // Process each balanceCheck while in range of the endIndex, summing the total balance to be paid
    //     while (lastBalanceCheckIndex <= endIndex) {
    //         BalanceCheck memory balanceCheck = _self._balanceChecks[lastBalanceCheckIndex];
    //         uint256 diff = balanceCheck.balance - lastBalancePulled;
    //         if (diff > 0 && balanceCheck.totalBps > 0) {
    //             // For each check, add (balanceCheck.balance - lastBalancePulled) * (accountBps / balanceCheck.totalBps)
    //             accountBalanceOwed += Math.mulDiv(diff, bps, balanceCheck.totalBps);
    //         }
    //         // Do not increment past the end of the balanceChecks array
    //         if (lastBalanceCheckIndex == latestBalanceCheckIndex) {
    //             // Track this balance to save to the account's storage as the lastPulledBalance
    //             unchecked {
    //                 lastBalancePulled = balanceCheck.balance;
    //             }
    //             break;
    //         }
    //         /**
    //          * @dev Notice that this increments the lastBalanceCheckIndex PAST the endIndex for an account that has had
    //          * their balance share removed at some point.
    //          *
    //          * This is the desired behavior. See the private _accountHasFinishedWithdrawals function. This considers an
    //          * account to be finished with withdrawals once the lastBalanceCheckIndex is greater than the endIndex.
    //          */
    //         unchecked {
    //             lastBalanceCheckIndex += 1;
    //             lastBalancePulled = 0;
    //         }
    //     }

    //     return (accountBalanceOwed, lastBalanceCheckIndex, lastBalancePulled);

    // }

    // /**
    //  * @dev Overload for when the reference is already present
    //  */
    // function _accountHasFinishedWithdrawals(
    //     AccountShare storage accountShare
    // ) private view returns (bool) {
    //     (uint256 createdAt, uint256 lastBalanceCheckIndex, uint256 endIndex) = (
    //         accountShare.createdAt,
    //         accountShare.lastBalanceCheckIndex,
    //         accountShare.endIndex
    //     );
    //     return _accountHasFinishedWithdrawals(createdAt, lastBalanceCheckIndex, endIndex);
    // }

    // /**
    //  * @dev Overload for checking if these values are already loaded into memory (to save gas).
    //  */
    // function _accountHasFinishedWithdrawals(
    //     uint256 createdAt,
    //     uint256 lastBalanceCheckIndex,
    //     uint256 endIndex
    // ) private pure returns (bool) {
    //     return createdAt == 0 || lastBalanceCheckIndex > endIndex;
    // }

}