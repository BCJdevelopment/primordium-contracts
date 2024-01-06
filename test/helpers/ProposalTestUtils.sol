// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTest} from "test/Base.t.sol";

contract ProposalTestUtils is BaseTest {
    /// @dev Makes external call to governor for proposal count, so call this before any call expectations are set
    function _expectedProposalId() internal view returns (uint256 expectedProposalId) {
        expectedProposalId = governor.proposalCount() + 1;
    }

    function _propose(
        address proposer,
        address target,
        uint256 value,
        bytes memory data,
        string memory signature,
        string memory description
    ) internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        string[] memory signatures = new string[](1);
        signatures[0] = signature;

        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, signatures, description);
    }

    function _queue(
        uint256 proposalId,
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (uint256) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;

        return governor.queue(proposalId, targets, values, calldatas);
    }

    function _execute(
        uint256 proposalId,
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (uint256) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;

        return governor.execute(proposalId, targets, values, calldatas);
    }
}
