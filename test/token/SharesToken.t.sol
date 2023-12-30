// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTest} from "test/Base.t.sol";
import {ISharesToken} from "src/token/interfaces/ISharesToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SharesTokenTest is BaseTest {
    uint256 gwartShares = 200;
    uint256 bobShares = 300;
    uint256 aliceShares = 500;

    function setUp() public virtual override {
        super.setUp();
        // Mint shares to gwart, bob, and alice
        vm.startPrank(token.owner());
        token.mint(users.gwart, gwartShares);
        token.mint(users.bob, bobShares);
        token.mint(users.alice, aliceShares);
        vm.stopPrank();
    }

    function test_TotalSupply() public {
        assertEq(token.totalSupply(), gwartShares + bobShares + aliceShares);
    }

    function test_SetMaxSupply() public {
        uint256 newMaxSupply = uint256(type(uint208).max) + 1;
        vm.startPrank(token.owner());
        vm.expectRevert(abi.encodeWithSelector(ISharesToken.MaxSupplyTooLarge.selector, type(uint208).max));
        token.setMaxSupply(newMaxSupply);

        newMaxSupply = type(uint208).max;
        vm.expectEmit(false, false, false, true, address(token));
        emit ISharesToken.MaxSupplyChange(token.maxSupply(), newMaxSupply);
        token.setMaxSupply(newMaxSupply);
        vm.stopPrank();
    }

    function test_Mint() public {

    }

    function test_Transfer() public {
        // Transfer half of gwart's shares to alice
        uint256 cachedTotalSupply = token.totalSupply();
        uint256 transferAmount = gwartShares / 2;
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(users.gwart, users.alice, transferAmount);
        vm.prank(users.gwart);
        token.transfer(users.alice, transferAmount);
        assertEq(gwartShares - transferAmount, token.balanceOf(users.gwart));
        assertEq(aliceShares + transferAmount, token.balanceOf(users.alice));
        // Total supply should not change
        assertEq(cachedTotalSupply, token.totalSupply());

        // Transfer double of what gwart has left, which should revert
        transferAmount = gwartShares;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                users.gwart,
                token.balanceOf(users.gwart),
                transferAmount
            )
        );
        vm.prank(users.gwart);
        token.transfer(users.alice, transferAmount);
        assertEq(cachedTotalSupply, token.totalSupply());
    }

    function test_Fuzz_Transfer(uint8 transferAmount) public {
        // Transfer half of gwart's shares to alice
        uint256 cachedTotalSupply = token.totalSupply();

        if (transferAmount <= gwartShares) {
            vm.expectEmit(true, true, false, true);
            emit IERC20.Transfer(users.gwart, users.alice, transferAmount);
            vm.prank(users.gwart);
            token.transfer(users.alice, transferAmount);
            assertEq(gwartShares - transferAmount, token.balanceOf(users.gwart));
            assertEq(aliceShares + transferAmount, token.balanceOf(users.alice));
            // Total supply should not change
            assertEq(cachedTotalSupply, token.totalSupply());
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector,
                    users.gwart,
                    token.balanceOf(users.gwart),
                    transferAmount
                )
            );
            vm.prank(users.gwart);
            token.transfer(users.alice, transferAmount);
            assertEq(cachedTotalSupply, token.totalSupply());
        }
    }

    function test_TransferFrom() public {
        // Approve bob to send half of gwart's shares to alice
        uint256 cachedTotalSupply = token.totalSupply();
        uint256 transferAmount = gwartShares / 2;
        vm.prank(users.gwart);
        token.approve(users.bob, transferAmount);
        assertEq(token.allowance(users.gwart, users.bob), transferAmount);

        // Bob sends the amount from gwart to alice
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(users.gwart, users.alice, transferAmount);
        vm.prank(users.bob);
        token.transferFrom(users.gwart, users.alice, transferAmount);
        assertEq(gwartShares - transferAmount, token.balanceOf(users.gwart));
        assertEq(aliceShares + transferAmount, token.balanceOf(users.alice));
        // Total supply should not change
        assertEq(cachedTotalSupply, token.totalSupply());

        // Bob attempts to send more, which should revert with insufficient allowance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, users.bob, 0, transferAmount)
        );
        vm.prank(users.bob);
        token.transferFrom(users.gwart, users.alice, transferAmount);

        // Bob is approved to spend more, but gwart does not have enough balance
        transferAmount = gwartShares;
        vm.prank(users.gwart);
        token.approve(users.bob, transferAmount);
        assertEq(token.allowance(users.gwart, users.bob), transferAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                users.gwart,
                token.balanceOf(users.gwart),
                transferAmount
            )
        );
        vm.prank(users.bob);
        token.transferFrom(users.gwart, users.alice, transferAmount);
    }

    function test_Fuzz_TransferFrom(uint8 transferAmount, uint8 allowance) public {
        // Approve bob to send half of gwart's shares to alice
        uint256 cachedTotalSupply = token.totalSupply();

        vm.prank(users.gwart);
        token.approve(users.bob, allowance);
        assertEq(token.allowance(users.gwart, users.bob), allowance);

        bool noRevert;
        if (transferAmount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, users.bob, allowance, transferAmount)
            );
        } else {
            if (transferAmount > gwartShares) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientBalance.selector,
                        users.gwart,
                        token.balanceOf(users.gwart),
                        transferAmount
                    )
                );
            } else {
                vm.expectEmit(true, true, false, true);
                emit IERC20.Transfer(users.gwart, users.alice, transferAmount);
                noRevert = true;
            }
        }
        vm.prank(users.bob);
        token.transferFrom(users.gwart, users.alice, transferAmount);
        if (noRevert) {
            assertEq(gwartShares - transferAmount, token.balanceOf(users.gwart));
            assertEq(aliceShares + transferAmount, token.balanceOf(users.alice));
        } else {
            assertEq(gwartShares, token.balanceOf(users.gwart));
            assertEq(aliceShares, token.balanceOf(users.alice));
        }
        // Total supply should not change
        assertEq(cachedTotalSupply, token.totalSupply());
    }

}
