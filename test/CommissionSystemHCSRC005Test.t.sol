// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { CommissionSystem } from "../src/CommissionSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";
import { StakingContract } from "../src/StakingContract.sol";

/// @dev Regresiones de HC-SRC-005: CommissionSystem consulta el beneficio de
/// no pagar comision de StakingContract. Un pagador con el beneficio no paga
/// la comision, y el beneficiario recibe lo mismo que sin el.
contract CommissionSystemHCSRC005Test is Test {
    CommissionSystem commission;
    StakingContract staking;
    HackToken token;

    address TREASURY = makeAddr("treasury");
    address PAYER = makeAddr("payer");
    address PAYEE = makeAddr("payee");
    address STRANGER = makeAddr("stranger");

    uint256 constant GROSS = 1_000 ether;
    uint256 constant FEE = 50 ether; // 5% por defecto
    uint256 constant STAKE = 100_000 ether;

    function setUp() public {
        token = new HackToken(address(this));
        IncentivesPool pool = new IncentivesPool(address(token));
        staking = new StakingContract(address(token), address(pool), address(new RoleRegistry()));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(staking));

        commission = new CommissionSystem(address(token), TREASURY, address(staking));
        commission.grantRole(commission.TRANSACTION_ROLE(), address(this));

        token.mintTokens(PAYER, STAKE + 10_000 ether);
        vm.startPrank(PAYER);
        token.approve(address(staking), STAKE);
        token.approve(address(commission), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Stake de 100.000 HACK a un ano, madurado y con el beneficio activo.
    function _activateBenefit() internal {
        uint256 oneYear = staking.ONE_YEAR();
        vm.startPrank(PAYER);
        staking.stake(STAKE, oneYear);
        vm.warp(block.timestamp + oneYear);
        staking.activateNoCommission(0);
        vm.stopPrank();
        assertTrue(staking.hasNoCommission(PAYER));
    }

    function _collect(bytes32 evidenceId_) internal returns (uint256 net) {
        net = commission.collectCommission(evidenceId_, PAYER, PAYEE, GROSS, "payment");
    }

    function test_HCSRC005_EligiblePayerPaysNoCommission() public {
        _activateBenefit();
        uint256 payerBefore = token.balanceOf(PAYER);

        uint256 net = _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), 0, "treasury receives nothing");
        assertEq(payerBefore - token.balanceOf(PAYER), GROSS - FEE, "payer saves the commission");
        assertEq(token.balanceOf(PAYEE), GROSS - FEE, "payee receives the usual net");
        assertEq(net, GROSS - FEE, "returned net matches what the payee got");
        assertEq(commission.totalCommissionsCollected(), 0, "no commission accounted");
    }

    function test_HCSRC005_IneligiblePayerPaysTheConfiguredCommission() public {
        uint256 payerBefore = token.balanceOf(PAYER);

        _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), FEE, "treasury gets 5%");
        assertEq(payerBefore - token.balanceOf(PAYER), GROSS, "payer pays the gross amount");
        assertEq(token.balanceOf(PAYEE), GROSS - FEE, "payee gets the net");
    }

    /// @dev El beneficiario cobra lo mismo tenga o no el pagador la exencion.
    function test_HCSRC005_PayeeReceivesTheSameWithOrWithoutTheBenefit() public {
        _collect(keccak256("before"));
        uint256 withoutBenefit = token.balanceOf(PAYEE);

        _activateBenefit();
        _collect(keccak256("after"));

        assertEq(token.balanceOf(PAYEE) - withoutBenefit, withoutBenefit, "same net in both cases");
    }

    function test_HCSRC005_CommissionReturnsAfterBenefitIsDeactivated() public {
        _activateBenefit();
        vm.prank(PAYER);
        staking.deactivateNoCommission();

        _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), FEE, "the commission is charged again");
    }

    function test_HCSRC005_CommissionReturnsAfterBackingStakeIsWithdrawn() public {
        _activateBenefit();
        vm.prank(PAYER);
        staking.withdrawPrincipal(0);

        _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), FEE, "without the backing stake there is no exemption");
    }

    function test_HCSRC005_WaiverIsRecordedInAnEvent() public {
        _activateBenefit();
        bytes32 evidenceId = keccak256("tx");

        vm.expectEmit(true, true, false, true);
        emit CommissionSystem.CommissionWaived(evidenceId, PAYER, FEE);
        _collect(evidenceId);
    }

    function test_HCSRC005_PreviewForReflectsTheExemption() public {
        (uint256 feeBefore, uint256 paysBefore, uint256 receivesBefore) =
            commission.previewCommissionFor(PAYER, GROSS);
        assertEq(feeBefore, FEE);
        assertEq(paysBefore, GROSS);
        assertEq(receivesBefore, GROSS - FEE);

        _activateBenefit();
        (uint256 feeAfter, uint256 paysAfter, uint256 receivesAfter) =
            commission.previewCommissionFor(PAYER, GROSS);
        assertEq(feeAfter, 0, "no commission with the benefit");
        assertEq(paysAfter, GROSS - FEE, "the payer pays only the net");
        assertEq(receivesAfter, GROSS - FEE, "the payee receives the same");
    }

    function test_HCSRC005_AdminCanUpdateTheStakingSource() public {
        address newStaking = makeAddr("new-staking");

        vm.expectEmit(true, true, false, false);
        emit CommissionSystem.StakingContractUpdated(address(staking), newStaking);
        commission.setStakingContract(newStaking);

        assertEq(address(commission.stakingContract()), newStaking);
    }

    function test_HCSRC005_StakingSourceRejectsZeroAndNonAdmins() public {
        vm.expectRevert(CommissionSystem.InvalidAddress.selector);
        commission.setStakingContract(address(0));

        bytes32 adminRole = commission.DEFAULT_ADMIN_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, adminRole)
        );
        commission.setStakingContract(makeAddr("new-staking"));
    }

    function test_HCSRC005_ConstructorRejectsZeroStakingSource() public {
        vm.expectRevert(CommissionSystem.InvalidAddress.selector);
        new CommissionSystem(address(token), TREASURY, address(0));
    }
}
