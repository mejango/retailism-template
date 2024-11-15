// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook/src/JB721TiersHookDeployer.sol";
    import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core/src/CTPublisher.sol";

import "@bananapus/core/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/swap-terminal/script/helpers/SwapTerminalDeploymentLib.sol";
import "@bananapus/buyback-hook/script/helpers/BuybackDeploymentLib.sol";

import {JBConstants} from "@bananapus/core/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core/src/structs/JBAccountingContext.sol";
import {MockPriceFeed} from "@bananapus/core/test/mock/MockPriceFeed.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVAutoIssuance} from "../src/structs/REVAutoIssuance.sol";
import {REVStageConfig} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVBuybackPoolConfig} from "../src/structs/REVBuybackPoolConfig.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry/src/interfaces/IJBAddressRegistry.sol";

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVBuybackHookConfig buybackHookConfiguration;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract REVLoansSourcedTests is TestBaseWorkflow, JBTest {
    /// @notice the salts that are used to deploy the contracts.
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;

    /// @notice Deploys tiered ERC-721 hooks for revnets.
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;

    IREVLoans LOANS_CONTRACT;

    /// @notice Deploys and tracks suckers for revnets.
    IJBSuckerRegistry SUCKER_REGISTRY;

    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER = makeAddr("user");

    /// @notice The address that is allowed to forward calls.
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        // Define constants
        string memory name = "Revnet";
        string memory symbol = "$REV";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx";
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        // The tokens that the project accepts and stores.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);

        // Accept the chain's native currency through the multi terminal.
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // The terminals that the project will accept funds through.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        // The project's revnet stage configurations.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                chainId: uint32(block.chainid),
                count: uint104(70_000 * decimalMultiplier),
                beneficiary: multisig()
            });

            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: uint40(block.timestamp),
                autoIssuance: issuanceConfs,
                splitPercent: 2000, // 20%
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceDecayFrequency: 90 days,
                issuanceDecayPercent: JBConstants.MAX_DECAY_PERCENT / 2,
                cashOutTaxRate: 6000, // 0.6
                extraMetadata: 0
            });
        }

        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 720 days),
            autoIssuance: new REVAutoIssuance[](0),
            splitPercent: 2000, // 20%
            initialIssuance: 0, // inherit from previous cycle.
            issuanceDecayFrequency: 180 days,
            issuanceDecayPercent: JBConstants.MAX_DECAY_PERCENT / 2,
            cashOutTaxRate: 1000, // 0.1
            extraMetadata: 0
        });

        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + (20 * 365 days)),
            autoIssuance: new REVAutoIssuance[](0),
            splitPercent: 0,
            initialIssuance: 1, // this is a special number that is as close to max price as we can get.
            issuanceDecayFrequency: 0,
            issuanceDecayPercent: 0,
            cashOutTaxRate: 6000, // 0.6
            extraMetadata: 0
        });

        REVLoanSource[] memory _loanSources = new REVLoanSource[](0);

        // The project's revnet configuration
        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription(name, symbol, projectUri, ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: _loanSources,
            loans: address(0)
        });

        // The project's buyback hook configuration.
        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] = REVBuybackPoolConfig({
            token: JBConstants.NATIVE_TOKEN,
            fee: 10_000,
            twapWindow: 2 days,
            twapSlippageTolerance: 9000
        });
        REVBuybackHookConfig memory buybackHookConfiguration =
            REVBuybackHookConfig({hook: IJBBuybackHook(address(0)), poolConfigurations: buybackPoolConfigurations});

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function getSecondProjectConfig() internal view returns (FeeProjectConfig memory) {
        // Define constants
        string memory name = "NANA";
        string memory symbol = "$NANA";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNxosvuhX21wkF3tx";
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        // The tokens that the project accepts and stores.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);

        // Accept the chain's native currency through the multi terminal.
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // The terminals that the project will accept funds through.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        // The project's revnet stage configurations.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                chainId: uint32(block.chainid),
                count: uint104(70_000 * decimalMultiplier),
                beneficiary: multisig()
            });

            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: uint40(block.timestamp),
                autoIssuance: issuanceConfs,
                splitPercent: 2000, // 20%
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceDecayFrequency: 90 days,
                issuanceDecayPercent: JBConstants.MAX_DECAY_PERCENT / 2,
                cashOutTaxRate: 0, //6000, // 0.6
                extraMetadata: 0
            });
        }

        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 720 days),
            autoIssuance: new REVAutoIssuance[](0),
            splitPercent: 2000, // 20%
            initialIssuance: 0, // inherit from previous cycle.
            issuanceDecayFrequency: 180 days,
            issuanceDecayPercent: JBConstants.MAX_DECAY_PERCENT / 2,
            cashOutTaxRate: 0, //6000, // 0.6
            extraMetadata: 0
        });

        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + (20 * 365 days)),
            autoIssuance: new REVAutoIssuance[](0),
            splitPercent: 0,
            initialIssuance: 1, // this is a special number that is as close to max price as we can get.
            issuanceDecayFrequency: 0,
            issuanceDecayPercent: 0,
            cashOutTaxRate: 0, //6000, // 0.6
            extraMetadata: 0
        });

        REVLoanSource[] memory _loanSources = new REVLoanSource[](1);
        _loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // The project's revnet configuration
        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription(name, symbol, projectUri, "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: _loanSources,
            loans: address(LOANS_CONTRACT)
        });

        // The project's buyback hook configuration.
        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] = REVBuybackPoolConfig({
            token: JBConstants.NATIVE_TOKEN,
            fee: 10_000,
            twapWindow: 2 days,
            twapSlippageTolerance: 9000
        });
        REVBuybackHookConfig memory buybackHookConfiguration =
            REVBuybackHookConfig({hook: IJBBuybackHook(address(0)), poolConfigurations: buybackPoolConfigurations});

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("NANA"))
            })
        });
    }

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig());

        HOOK_STORE = new JB721TiersHookStore();

        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());

        ADDRESS_REGISTRY = new JBAddressRegistry();

        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());

        PUBLISHER = new CTPublisher(jbController(), jbPermissions(), FEE_PROJECT_ID, multisig());

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER
        );

        LOANS_CONTRACT = new REVLoans({
            projects: jbProjects(),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        // Approve the basic deployer to configure the project.
        vm.prank(address(multisig()));
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Build the config.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();

        // Configure the project.
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID, // Zero to deploy a new revnet
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            buybackHookConfiguration: feeProjectConfig.buybackHookConfiguration,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration
        });

        // Configure second revnet
        FeeProjectConfig memory fee2Config = getSecondProjectConfig();

        // Configure the project.
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: 0, // Zero to deploy a new revnet
            configuration: fee2Config.configuration,
            terminalConfigurations: fee2Config.terminalConfigurations,
            buybackHookConfiguration: fee2Config.buybackHookConfiguration,
            suckerDeploymentConfiguration: fee2Config.suckerDeploymentConfiguration
        });

        // Give Eth for the user experience
        vm.deal(USER, 100e18);
    }

    function test_Pay_Borrow_With_Loan_Source() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);
        assertEq(loan.amount, loanable);
        assertEq(loan.collateral, tokens);
        assertEq(loan.createdAt, block.timestamp);
        assertEq(loan.prepaidFeePercent, 500);
        assertEq(loan.prepaidDuration, mulDiv(500, 3650 days, 500));
        assertEq(loan.source.token, JBConstants.NATIVE_TOKEN);
        assertEq(address(loan.source.terminal), address(jbMultiTerminal()));

        // Ensure loans contract isn't hodling
        assertEq(address(LOANS_CONTRACT).balance, 0);

        // Ensure we actually received ETH from the borrow
        assertGt(USER.balance, 100e18 - 1e18);
    }

    function testFuzz_Pay_Borrow_PayOff_With_Loan_Source(
        uint256 percentOfCollateralToRemove,
        uint256 prepaidFeePercent,
        uint256 daysToWarp
    )
        public
    {
        ///
        percentOfCollateralToRemove = bound(percentOfCollateralToRemove, 0, 10_000);
        prepaidFeePercent = bound(prepaidFeePercent, 25, 500);
        daysToWarp = bound(daysToWarp, 0, 3650);

        daysToWarp = daysToWarp * 1 days;

        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        uint256 newLoanId;

        {
            REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

            vm.prank(USER);
            (newLoanId,) =
                LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), prepaidFeePercent);
        }

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        assertEq(loan.amount, loanable);
        assertEq(loan.collateral, tokens);
        assertEq(loan.createdAt, block.timestamp);
        assertEq(loan.prepaidFeePercent, prepaidFeePercent);
        assertEq(loan.prepaidDuration, mulDiv(prepaidFeePercent, 3650 days, 500));
        assertEq(loan.source.token, JBConstants.NATIVE_TOKEN);
        assertEq(address(loan.source.terminal), address(jbMultiTerminal()));

        // warp forward
        vm.warp(block.timestamp + daysToWarp);

        uint256 collateralReturned = mulDiv(loan.collateral, percentOfCollateralToRemove, 10_000);

        uint256 newCollateral = loan.collateral - collateralReturned;
        uint256 borrowableFromNewCollateral =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, newCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Needed for edge case seeds like 17721, 11407, 334
        if (borrowableFromNewCollateral > 0) borrowableFromNewCollateral -= 1;

        uint256 amountDiff = borrowableFromNewCollateral > loan.amount ? 0 : loan.amount - borrowableFromNewCollateral;

        uint256 amountPaidDown = amountDiff;

        // Calculate the fee.
        {
            // Keep a reference to the time since the loan was created.
            uint256 timeSinceLoanCreated = block.timestamp - loan.createdAt;

            // If the loan period has passed the prepaid time frame, take a fee.
            if (timeSinceLoanCreated > loan.prepaidDuration) {
                // Calculate the prepaid fee for the amount being paid back.
                uint256 prepaidAmount = JBFees.feeAmountFrom({amount: amountDiff, feePercent: loan.prepaidFeePercent});

                // Calculate the fee as a linear proportion given the amount of time that has passed.
                // sourceFeeAmount = mulDiv(amount, timeSinceLoanCreated, LOAN_LIQUIDATION_DURATION) - prepaidAmount;
                amountPaidDown += JBFees.feeAmountFrom({
                    amount: amountDiff - prepaidAmount,
                    feePercent: mulDiv(timeSinceLoanCreated, JBConstants.MAX_FEE, 3650 days)
                });
            }
        }

        // ensure we have the balance
        vm.deal(USER, amountPaidDown);

        // empty allowance data
        JBSingleAllowance memory allowance;

        // call to pay-down the loan
        vm.prank(USER);
        (, REVLoan memory reducedLoan) = LOANS_CONTRACT.repayLoan{value: amountPaidDown}(
            newLoanId, amountPaidDown, collateralReturned, payable(USER), allowance
        );

        assertApproxEqAbs(reducedLoan.amount, loan.amount - amountDiff, 1);
        assertEq(reducedLoan.collateral, loan.collateral - collateralReturned);
        assertEq(reducedLoan.createdAt, block.timestamp - daysToWarp);
        assertEq(reducedLoan.prepaidFeePercent, prepaidFeePercent);
        assertEq(reducedLoan.prepaidDuration, mulDiv(prepaidFeePercent, 3650 days, 500));
        assertEq(reducedLoan.source.token, JBConstants.NATIVE_TOKEN);
        assertEq(address(reducedLoan.source.terminal), address(jbMultiTerminal()));
    }

    function test_Refinance_Excess_Collateral() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        // Ensure loans contract isn't hodling
        assertEq(address(LOANS_CONTRACT).balance, 0);

        // Ensure we actually received ETH from the borrow
        assertGt(USER.balance, 100e18 - 1e18);

        // warp to after redemption rate is higher in the second ruleset
        vm.warp(block.timestamp + 721 days);

        // get the updated loanableFrom the same amount as earlier
        uint256 loanableSecondStage = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, loan.collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // loanable amount is higher with the lower tax rate per second stage configuration
        assertGt(loanableSecondStage, loanable);

        // we should not have to add collateral
        uint256 collateralToAdd = 0;

        // this should be a 0.5% gain to be reallocated
        uint256 collateralToTransfer = mulDiv(loan.collateral, 50, 10_000);

        // get the new amount to borrow
        uint256 newAmount = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        uint256 userBalanceBefore = USER.balance;

        vm.prank(USER);
        (,, REVLoan memory adjustedLoan, REVLoan memory newLoan) = LOANS_CONTRACT.reallocateCollateralFromLoan(
            newLoanId, collateralToTransfer, sauce, newAmount, collateralToAdd, payable(USER), 25
        );

        uint256 userBalanceAfter = USER.balance;

        // check we received funds period
        assertGt(userBalanceAfter, userBalanceBefore);
        // check we received ~newAmount with a 0.1% buffer
        assertApproxEqRel(userBalanceBefore + newLoan.amount, userBalanceAfter, 1e15);

        // Check the old loan has been adjusted
        assertEq(adjustedLoan.amount, loan.amount); // Should match the old loan
        assertEq(adjustedLoan.collateral, loan.collateral - collateralToTransfer); // should be reduced
        assertEq(adjustedLoan.createdAt, loan.createdAt); // Should match the old loan
        assertEq(adjustedLoan.prepaidFeePercent, loan.prepaidFeePercent); // Should match the old loan
        assertEq(adjustedLoan.prepaidDuration, mulDiv(loan.prepaidFeePercent, 3650 days, 500));
        assertEq(adjustedLoan.source.token, JBConstants.NATIVE_TOKEN);
        assertEq(address(adjustedLoan.source.terminal), address(jbMultiTerminal()));

        // Check the new loan with the excess from refinancing
        assertEq(newLoan.amount, newAmount); // Excess from reallocateCollateral
        assertEq(newLoan.collateral, collateralToTransfer); // Matches the amount transferred
        assertEq(newLoan.createdAt, block.timestamp);
        assertEq(newLoan.prepaidFeePercent, 25); // Configured as 25 (min) in reallocateCollateral call
        assertEq(newLoan.prepaidDuration, mulDiv(25, 3650 days, 500)); // Configured as 25 in reallocateCollateral call
        assertEq(newLoan.source.token, JBConstants.NATIVE_TOKEN);
        assertEq(address(newLoan.source.terminal), address(jbMultiTerminal()));
    }

    function test_Refinance_Not_Enough_Collateral() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        // Ensure loans contract isn't hodling
        assertEq(address(LOANS_CONTRACT).balance, 0);

        // Ensure we actually received ETH from the borrow
        assertGt(USER.balance, 100e18 - 1e18);

        // warp to after redemption rate is higher in the second ruleset
        vm.warp(block.timestamp + 721 days);

        // get the updated loanableFrom the same amount as earlier
        uint256 loanableSecondStage = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, loan.collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // loanable amount is higher with the lower tax rate per second stage configuration
        assertGt(loanableSecondStage, loanable);

        // we should not have to add collateral
        uint256 collateralToAdd = 0;

        // this should be a 0.5% gain to be reallocated
        uint256 collateralToTransfer = mulDiv(loan.collateral, 50, 10_000);

        // get the new amount to borrow
        uint256 newAmount = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        vm.expectRevert(REVLoans.REVLoans_NotEnoughCollateral.selector);
        vm.prank(USER);
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            // collateral exceeds with + 1
            newLoanId,
            loan.collateral + 1,
            sauce,
            newAmount,
            collateralToAdd,
            payable(USER),
            0
        );
    }

    function test_Refinance_Unauthorized() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        // Ensure loans contract isn't hodling
        assertEq(address(LOANS_CONTRACT).balance, 0);

        // Ensure we actually received ETH from the borrow
        assertGt(USER.balance, 100e18 - 1e18);

        // warp to after redemption rate is higher in the second ruleset
        vm.warp(block.timestamp + 721 days);

        // get the updated loanableFrom the same amount as earlier
        uint256 loanableSecondStage = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, loan.collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // loanable amount is higher with the lower tax rate per second stage configuration
        assertGt(loanableSecondStage, loanable);

        // we should not have to add collateral
        uint256 collateralToAdd = 0;

        // this should be a 0.5% gain to be reallocated
        uint256 collateralToTransfer = mulDiv(loan.collateral, 50, 10_000);

        // get the new amount to borrow
        uint256 newAmount = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        address unauthorized = address(1);
        vm.expectRevert(abi.encodeWithSelector(REVLoans.REVLoans_Unauthorized.selector, unauthorized, USER));

        vm.prank(unauthorized);
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            newLoanId, collateralToTransfer, sauce, newAmount, collateralToAdd, payable(USER), 25
        );
    }

    function test_Refinance_Unspecified_Amount() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        // Ensure loans contract isn't hodling
        assertEq(address(LOANS_CONTRACT).balance, 0);

        // Ensure we actually received ETH from the borrow
        assertGt(USER.balance, 100e18 - 1e18);

        // warp to after redemption rate is higher in the second ruleset
        vm.warp(block.timestamp + 721 days);

        // get the updated loanableFrom the same amount as earlier
        uint256 loanableSecondStage = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, loan.collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // loanable amount is higher with the lower tax rate per second stage configuration
        assertGt(loanableSecondStage, loanable);

        // we should not have to add collateral
        uint256 collateralToAdd = 0;

        // this should be a 0.5% gain to be reallocated
        uint256 collateralToTransfer = mulDiv(loan.collateral, 50, 10_000);

        // get the new amount to borrow
        uint256 newAmount = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        vm.expectRevert(REVLoans.REVLoans_AmountNotSpecified.selector);
        vm.prank(USER);
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            newLoanId,
            collateralToTransfer,
            sauce,
            0, // amount is zero
            collateralToAdd,
            payable(USER),
            0
        );
    }

    function test_Refinance_Collateral_Required() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        // Ensure loans contract isn't hodling
        assertEq(address(LOANS_CONTRACT).balance, 0);

        // Ensure we actually received ETH from the borrow
        assertGt(USER.balance, 100e18 - 1e18);

        // warp to after redemption rate is higher in the second ruleset
        vm.warp(block.timestamp + 721 days);

        // get the updated loanableFrom the same amount as earlier
        uint256 loanableSecondStage = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, loan.collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // loanable amount is higher with the lower tax rate per second stage configuration
        assertGt(loanableSecondStage, loanable);

        // we should not have to add collateral
        uint256 collateralToAdd = 0;

        // this should be a 0.5% gain to be reallocated
        uint256 collateralToTransfer = mulDiv(loan.collateral, 50, 10_000);

        // get the new amount to borrow
        uint256 newAmount = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        vm.expectRevert(REVLoans.REVLoans_CollateralRequired.selector);
        vm.prank(USER);
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            // attempt moving the total collateral
            newLoanId,
            loan.collateral,
            sauce,
            newAmount,
            collateralToAdd,
            payable(USER),
            0
        );
    }

    function testFuzz_Refinance(
        uint256 payAmount,
        uint256 collateralPercentToTransfer,
        uint256 secondPayAmount,
        uint256 prepaidFeePercent,
        uint256 daysToWarp
    )
        public
    {
        payAmount = bound(payAmount, 1e18, 100e18);
        secondPayAmount = bound(secondPayAmount, 1e18, 10e18);
        prepaidFeePercent = bound(prepaidFeePercent, 25, 500);
        daysToWarp = bound(daysToWarp, 0, 3650);
        daysToWarp = daysToWarp * 1 days;
        collateralPercentToTransfer = bound(collateralPercentToTransfer, 1, 1000);

        // pay once first to receive tokens for the borrow call
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: payAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // mock call spoofing permissions of REVLoans otherwise called by user before borrow.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 newLoanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 500);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(newLoanId);

        // warp to after redemption rate is higher in the second ruleset
        vm.warp(block.timestamp + daysToWarp);

        // pay again to have balance for the refinance
        uint256 tokens2 =
            jbMultiTerminal().pay{value: secondPayAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        // bound up to 1% reallocated
        uint256 collateralToTransfer = mulDiv(loan.collateral, collateralPercentToTransfer, 10_000);

        // get the new amount to borrow
        uint256 newAmount = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer + tokens2, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        uint256 userBalanceBefore = USER.balance;

        vm.prank(USER);
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            newLoanId, collateralToTransfer, sauce, newAmount, tokens2, payable(USER), 25
        );

        uint256 userBalanceAfter = USER.balance;

        // check we received funds period
        assertGt(userBalanceAfter, userBalanceBefore);
    }

    function test_loanSourcesOfAndDetermineSourceFeeAmount() external {
        // it will add the loan source upon first borrow
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Before a borrow the source does not exist
        REVLoanSource[] memory sources = LOANS_CONTRACT.loanSourcesOf(REVNET_ID);
        assertEq(sources.length, 0);

        vm.prank(USER);
        (, REVLoan memory loan) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 100);

        // Source should exist after a borrow
        REVLoanSource[] memory sourcesUpdated = LOANS_CONTRACT.loanSourcesOf(REVNET_ID);
        assertEq(sourcesUpdated.length, 1);
        assertEq(sourcesUpdated[0].token, JBConstants.NATIVE_TOKEN);
        assertEq(address(sourcesUpdated[0].terminal), address(jbMultiTerminal()));

        // Check the fee amount after warping forward past the prepaid duration
        vm.warp(block.timestamp + loan.prepaidDuration + 1 days);
        uint256 feeAmount = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertGt(feeAmount, 0);

        // Warp further than the loan liquidation duration to revert.
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                REVLoans.REVLoans_LoanExpired.selector, loan.prepaidDuration + 1 days + 3650 days, 3650 days
            )
        );

        LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
    }

    function test_borrowFromReverts() external {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        vm.expectRevert(REVLoans.REVLoans_AmountNotSpecified.selector);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, 0, tokens, payable(USER), 100);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(REVLoans.REVLoans_InvalidPrepaidFeePercent.selector, 1_000_000, 25, 500));
        LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, 1, tokens, payable(USER), 1_000_000);
    }

    function test_liquidateLoans() external {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 100);

        // Take out another loan
        vm.prank(USER);
        uint256 tokens2 = jbMultiTerminal().pay{value: 2e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable2 =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        vm.prank(USER);
        (uint256 loanId2, REVLoan memory loan2) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable2, tokens2, payable(USER), 50);

        // Warp further than the loan liquidation duration.
        vm.warp(block.timestamp + 10_000 days);

        // Check topics one and two
        vm.expectEmit(true, true, false, false);
        emit IREVLoans.Liquidate(loanId, REVNET_ID, loan, address(0));

        // Check for the second liquidation
        // Check topics one and two
        vm.expectEmit(true, true, false, false);
        emit IREVLoans.Liquidate(loanId2, REVNET_ID, loan2, address(0));
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 2);

        // Call again to trigger the first break (loan.createdAt = 0)
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 2);
    }

    function test_liquidationRevertsContinued() external {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 100);

        // Attempt to liquidate before the loan is expired and loop will break
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 1);

        // Repay the loan, adjusting the previous loan.
        uint256 collateralReturned = mulDiv(loan.collateral, 1000, 10_000);

        uint256 newCollateral = loan.collateral - collateralReturned;
        uint256 borrowableFromNewCollateral =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, newCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Needed for edge case seeds like 17721, 11407, 334
        if (borrowableFromNewCollateral > 0) borrowableFromNewCollateral -= 1;

        uint256 amountDiff = borrowableFromNewCollateral > loan.amount ? 0 : loan.amount - borrowableFromNewCollateral;

        uint256 amountPaidDown = amountDiff;

        // Calculate the fee.
        {
            // Keep a reference to the time since the loan was created.
            uint256 timeSinceLoanCreated = block.timestamp - loan.createdAt;

            // If the loan period has passed the prepaid time frame, take a fee.
            if (timeSinceLoanCreated > loan.prepaidDuration) {
                // Calculate the prepaid fee for the amount being paid back.
                uint256 prepaidAmount = JBFees.feeAmountFrom({amount: amountDiff, feePercent: loan.prepaidFeePercent});

                // Calculate the fee as a linear proportion given the amount of time that has passed.
                // sourceFeeAmount = mulDiv(amount, timeSinceLoanCreated, LOAN_LIQUIDATION_DURATION) - prepaidAmount;
                amountPaidDown += JBFees.feeAmountFrom({
                    amount: amountDiff - prepaidAmount,
                    feePercent: mulDiv(timeSinceLoanCreated, JBConstants.MAX_FEE, 3650 days)
                });
            }
        }

        // ensure we have the balance
        vm.deal(USER, amountPaidDown);

        // empty allowance data
        JBSingleAllowance memory allowance;

        // call to pay-down the loan
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: amountPaidDown}(
            loanId, amountPaidDown, collateralReturned, payable(USER), allowance
        );

        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 1);
    }

    function test_liquidationReturnCollateral() external {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 100);

        // Repay the loan, adjusting the previous loan.
        uint256 collateralReturned = 0;

        uint256 amountPaidDown = loan.amount;

        // Calculate the fee.
        {
            // Keep a reference to the time since the loan was created.
            uint256 timeSinceLoanCreated = block.timestamp - loan.createdAt;

            // If the loan period has passed the prepaid time frame, take a fee.
            if (timeSinceLoanCreated > loan.prepaidDuration) {
                // Calculate the prepaid fee for the amount being paid back.
                uint256 prepaidAmount =
                    JBFees.feeAmountFrom({amount: amountPaidDown, feePercent: loan.prepaidFeePercent});

                // Calculate the fee as a linear proportion given the amount of time that has passed.
                // sourceFeeAmount = mulDiv(amount, timeSinceLoanCreated, LOAN_LIQUIDATION_DURATION) - prepaidAmount;
                amountPaidDown += JBFees.feeAmountFrom({
                    amount: amountPaidDown - prepaidAmount,
                    feePercent: mulDiv(timeSinceLoanCreated, JBConstants.MAX_FEE, 3650 days)
                });
            }
        }

        amountPaidDown += 1e18;

        // ensure we have the balance
        vm.deal(USER, amountPaidDown);

        // empty allowance data
        JBSingleAllowance memory allowance;

        // call to pay-down the loan
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: amountPaidDown}(
            loanId, amountPaidDown, collateralReturned, payable(USER), allowance
        );

        // warp forward to where the loan is expired
        vm.warp(block.timestamp + 10_000 days);

        vm.expectEmit();
        emit IJBController.MintTokens(
            USER, REVNET_ID, 8e20, 8e20, "Removing collateral from loan", 0, address(LOANS_CONTRACT)
        );
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 2);
    }

    function test_repay_unauthorized() external {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 100);

        // empty allowance data
        JBSingleAllowance memory allowance;

        // call to pay-down the loan
        /* vm.prank(USER); */
        vm.expectRevert(abi.encodeWithSelector(REVLoans.REVLoans_Unauthorized.selector, address(this), USER));
        LOANS_CONTRACT.repayLoan{value: 0}(loanId, 0, 0, payable(USER), allowance);
    }

    function test_repay_return_invalid_collateral() external {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0);

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, 2, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, sauce, loanable, tokens, payable(USER), 100);

        // empty allowance data
        JBSingleAllowance memory allowance;

        // call to pay-down the loan
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                REVLoans.REVLoans_CollateralExceedsLoan.selector, loan.collateral + 1, loan.collateral
            )
        );
        LOANS_CONTRACT.repayLoan{value: 0}(
            // collateral exceeds with + 1
            loanId,
            0,
            loan.collateral + 1,
            payable(USER),
            allowance
        );
    }
}
