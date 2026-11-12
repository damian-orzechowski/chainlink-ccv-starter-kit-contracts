// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployBpsVerifier} from "../../script/deploy/DeployBpsVerifier.s.sol";
import {DeployVerifier} from "../../script/deploy/DeployVerifier.s.sol";
import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BpsFeeConfig} from "../../src/bps/BpsFeeConfig.sol";
import {MockRMN} from "../mocks/MockRMN.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The two deploy scripts differ only in the implementation they create and the
///         name they record; everything else is inherited from DeployVerifier.
contract DeployBpsVerifierTest is Test {
  bytes4 internal constant VERSION_TAG = bytes4(0x00020001);
  address internal constant FEE_AGGREGATOR = address(0xFEE1);
  address internal constant ALLOWLIST_ADMIN = address(0xA11);

  MockRMN internal rmn;

  function setUp() public {
    rmn = new MockRMN();
  }

  function test_createsBpsFeeCommitteeVerifier() public {
    BpsHarness harness = new BpsHarness();
    address verifier = harness.create(_dynamicConfig(), _storageLocations(), address(rmn), VERSION_TAG);

    assertEq(harness.contractName(), "BpsFeeCommitteeVerifier");
    // A bps-only getter answers, so this is the subclass and not a plain CommitteeVerifier.
    BpsFeeConfig memory cfg = BpsFeeCommitteeVerifier(verifier).getFeeConfig(1);
    assertFalse(cfg.enabled, "no bps policy until configured");
    assertEq(CommitteeVerifier(verifier).getDynamicConfig().feeAggregator, FEE_AGGREGATOR);
    assertEq(CommitteeVerifier(verifier).owner(), address(harness), "deployer owns it before handover");
  }

  function test_baseScriptStillCreatesCommitteeVerifier() public {
    CommitteeHarness harness = new CommitteeHarness();
    address verifier = harness.create(_dynamicConfig(), _storageLocations(), address(rmn), VERSION_TAG);

    assertEq(harness.contractName(), "CommitteeVerifier");
    vm.expectRevert();
    BpsFeeCommitteeVerifier(verifier).getFeeConfig(1);
  }

  function _dynamicConfig() internal pure returns (CommitteeVerifier.DynamicConfig memory) {
    return CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: ALLOWLIST_ADMIN});
  }

  function _storageLocations() internal pure returns (string[] memory locations) {
    locations = new string[](1);
    locations[0] = "https://agg.one";
  }
}

contract BpsHarness is DeployBpsVerifier {
  function create(
    CommitteeVerifier.DynamicConfig memory dynamicConfig,
    string[] memory storageLocations,
    address rmn,
    bytes4 versionTag
  ) external returns (address) {
    return address(_createVerifier(dynamicConfig, storageLocations, rmn, versionTag));
  }

  function contractName() external pure returns (string memory) {
    return _contractName();
  }
}

contract CommitteeHarness is DeployVerifier {
  function create(
    CommitteeVerifier.DynamicConfig memory dynamicConfig,
    string[] memory storageLocations,
    address rmn,
    bytes4 versionTag
  ) external returns (address) {
    return address(_createVerifier(dynamicConfig, storageLocations, rmn, versionTag));
  }

  function contractName() external pure returns (string memory) {
    return _contractName();
  }
}
