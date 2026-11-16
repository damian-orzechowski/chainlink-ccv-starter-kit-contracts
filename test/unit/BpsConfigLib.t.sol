// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsFeeConfig} from "../../src/bps/BpsFeeConfig.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @dev External seam: vm.expectRevert needs the revert one call deeper than the test.
contract BpsConfigHarness {
  function readLane(
    string calldata path
  ) external view returns (BpsConfigLib.LaneBpsFee memory) {
    return BpsConfigLib.readLaneBpsFeeByPath(path);
  }

  function readPolicies(
    string calldata path
  ) external view returns (BpsConfigLib.VerifierBpsPolicy[] memory) {
    return BpsConfigLib.readVerifierPoliciesByPath(path);
  }

  function requireBpsVerifier(
    Types.Deployment calldata deployment,
    bytes4 tag
  ) external pure {
    BpsConfigLib.requireBpsVerifier(deployment, tag);
  }
}

/// @notice The bps-only config keys: the lane `bpsFeeConfig` block (bounds mirror
///         setFeeConfig, which validate-config reports through this loader), the verifier
///         entry's `requireAllTokensPriced`, and the record check the configure script
///         runs first.
/// @dev Forge runs tests concurrently against one filesystem, so every fixture is its own
///      path under out/governance/; the trailing removeFile is courtesy only.
contract BpsConfigLibTest is Test {
  string internal constant DIR = "out/governance/";
  bytes4 internal constant TAG = 0x00010001; // catalogued in config/operator.example.json

  BpsConfigHarness internal harness;

  function setUp() public {
    vm.createDir("out/governance", true);
    harness = new BpsConfigHarness();
  }

  // ===========================================================================
  //  lane bpsFeeConfig
  // ===========================================================================

  /// @dev Every pre-existing lane file has no bpsFeeConfig: it must read as the default.
  function test_lane_absentBlockReadsAsDisabled() public view {
    BpsConfigLib.LaneBpsFee memory lane = harness.readLane("config/operator/lanes/sepolia-to-base_sepolia.example.json");
    assertEq(lane.laneName, "sepolia-to-base_sepolia");
    assertEq(lane.sourceAlias, "sepolia");
    assertEq(lane.destSelector, 10344971235874465080);
    assertEq(lane.versionTag, TAG);
    assertFalse(BpsConfigLib.isDeclared(lane.fee), "absent block is the contract default");
  }

  function test_lane_parsesTheBlock() public {
    BpsConfigLib.LaneBpsFee memory lane =
      _readLane("parse", '{"enabled":true,"feeBps":5,"minFeeUSDCents":50,"capUSDCents":5000}');
    assertTrue(lane.fee.enabled);
    assertEq(lane.fee.feeBps, 5);
    assertEq(lane.fee.minFeeUSDCents, 50);
    assertEq(lane.fee.capUSDCents, 5000);
    assertTrue(BpsConfigLib.isDeclared(lane.fee));
  }

  function test_lane_acceptsTheUpperBounds() public {
    BpsConfigLib.LaneBpsFee memory lane =
      _readLane("upper", '{"enabled":true,"feeBps":10000,"minFeeUSDCents":65535,"capUSDCents":65535}');
    assertEq(lane.fee.feeBps, 10_000);
    assertEq(lane.fee.capUSDCents, 65_535);
  }

  /// @dev Disabled is how a policy is parked; a zero floor is fine there (setFeeConfig agrees).
  function test_lane_disabledAllowsAZeroFloor() public {
    BpsConfigLib.LaneBpsFee memory lane =
      _readLane("disabled", '{"enabled":false,"feeBps":5,"minFeeUSDCents":0,"capUSDCents":100}');
    assertFalse(lane.fee.enabled);
  }

  function test_lane_rejectsFeeBpsAbove10000() public {
    _expectLaneRevert(
      "bps-high", '{"enabled":true,"feeBps":10001,"minFeeUSDCents":1,"capUSDCents":1}', "feeBps must be <= 10000"
    );
  }

  function test_lane_rejectsCapBelowFloor() public {
    _expectLaneRevert(
      "cap-low",
      '{"enabled":true,"feeBps":5,"minFeeUSDCents":100,"capUSDCents":99}',
      "capUSDCents must be >= minFeeUSDCents"
    );
  }

  /// @dev The contract checks the floor rule on a disabled policy too.
  function test_lane_rejectsCapBelowFloorEvenWhenDisabled() public {
    _expectLaneRevert(
      "cap-low-off",
      '{"enabled":false,"feeBps":5,"minFeeUSDCents":100,"capUSDCents":99}',
      "capUSDCents must be >= minFeeUSDCents"
    );
  }

  function test_lane_rejectsAZeroFloorWhenEnabled() public {
    _expectLaneRevert(
      "floor-zero",
      '{"enabled":true,"feeBps":5,"minFeeUSDCents":0,"capUSDCents":100}',
      "minFeeUSDCents must be non-zero when enabled"
    );
  }

  function test_lane_rejectsAValueBeyondUint16() public {
    _expectLaneRevert(
      "overflow",
      '{"enabled":true,"feeBps":5,"minFeeUSDCents":1,"capUSDCents":65536}',
      "bpsFeeConfig.capUSDCents in out/governance/zz-scratch-bps-overflow.json exceeds uint16"
    );
  }

  function test_lane_rejectsAnUnknownKey() public {
    _expectLaneRevert(
      "unknown",
      '{"enabled":true,"feeBps":5,"minFeeUSDCents":1,"capUSDCents":10,"feeUSDCents":3}',
      "has unknown key 'feeUSDCents'"
    );
  }

  /// @dev A missing key must not read as zero: a dropped cap would silently clamp to 0.
  function test_lane_rejectsAMissingKey() public {
    _expectLaneRevert("missing", '{"enabled":true,"feeBps":5,"minFeeUSDCents":1}', "missing .bpsFeeConfig.capUSDCents");
  }

  // ===========================================================================
  //  operator verifiers[].requireAllTokensPriced
  // ===========================================================================

  function test_policies_readEachEntryAndDefaultToFalse() public {
    string memory path = string.concat(DIR, "zz-scratch-bps-policies.json");
    vm.writeFile(
      path,
      string.concat(
        '{"alias":"zz-scratch","verifiers":[',
        _verifierEntry("0x00010001", ""),
        ",",
        _verifierEntry("0x00010002", ',"requireAllTokensPriced":true'),
        "],",
        _resolverAndFactory(),
        "}"
      )
    );
    BpsConfigLib.VerifierBpsPolicy[] memory policies = harness.readPolicies(path);
    vm.removeFile(path);

    assertEq(policies.length, 2);
    assertFalse(BpsConfigLib.requireAllTokensPricedFor(policies, 0x00010001), "absent key is false");
    assertTrue(BpsConfigLib.requireAllTokensPricedFor(policies, 0x00010002));
    assertFalse(BpsConfigLib.requireAllTokensPricedFor(policies, 0x00010003), "no entry is false");
  }

  function test_policies_exampleOperatorFileReadsDefault() public view {
    BpsConfigLib.VerifierBpsPolicy[] memory policies =
      harness.readPolicies("config/operator/chains/sepolia.example.json");
    for (uint256 i = 0; i < policies.length; ++i) {
      assertFalse(policies[i].requireAllTokensPriced);
    }
  }

  // ===========================================================================
  //  record: the tag must be a BpsFeeCommitteeVerifier
  // ===========================================================================

  function test_requireBpsVerifier_passesForABpsRecord() public view {
    harness.requireBpsVerifier(_record("BpsFeeCommitteeVerifier"), TAG);
  }

  function test_requireBpsVerifier_rejectsAStockRecord() public {
    vm.expectRevert(
      bytes(
        "BpsConfigLib: verifier 0x00010001 on zz-scratch is recorded as CommitteeVerifier, not BpsFeeCommitteeVerifier - bps settings apply only to a verifier deployed with make deploy-bps-verifier"
      )
    );
    harness.requireBpsVerifier(_record("CommitteeVerifier"), TAG);
  }

  /// @dev Records written before the contract key existed name no contract: stock.
  function test_requireBpsVerifier_rejectsALegacyUnnamedRecord() public {
    vm.expectRevert();
    harness.requireBpsVerifier(_record(""), TAG);
  }

  function test_requireBpsVerifier_rejectsAnUnrecordedTag() public {
    vm.expectRevert(
      bytes("ConfigLib: no verifier with versionTag 0x00010002 recorded for zz-scratch - deploy that verifier first")
    );
    harness.requireBpsVerifier(_record("BpsFeeCommitteeVerifier"), 0x00010002);
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  function _record(
    string memory contractName
  ) internal pure returns (Types.Deployment memory deployment) {
    deployment.aliasName = "zz-scratch";
    deployment.verifiers = new Types.VerifierDeployment[](1);
    deployment.verifiers[0].versionTag = TAG;
    deployment.verifiers[0].addr = address(0xB0);
    deployment.verifiers[0].contractName = contractName;
  }

  function _lanePath(
    string memory name
  ) internal pure returns (string memory) {
    return string.concat(DIR, "zz-scratch-bps-", name, ".json");
  }

  /// @dev An explicit router keeps the standard loader off config/chains/.
  function _writeLane(
    string memory name,
    string memory bpsBlock
  ) internal returns (string memory path) {
    path = _lanePath(name);
    vm.writeFile(
      path,
      string.concat(
        '{"name":"zz-scratch-bps-',
        name,
        '","source":{"alias":"zz-src","chainSelector":"1111"},"dest":{"alias":"zz-dst","chainSelector":"2222"},',
        '"versionTag":"0x00010001",',
        '"remoteChainConfig":{"router":"0x0000000000000000000000000000000000009001","feeUSDCents":0,"gasForVerification":200000,"payloadSizeBytes":0},',
        '"allowlist":{"allowlistEnabled":false,"allowedSenders":[]},',
        '"bpsFeeConfig":',
        bpsBlock,
        "}"
      )
    );
  }

  function _readLane(
    string memory name,
    string memory bpsBlock
  ) internal returns (BpsConfigLib.LaneBpsFee memory lane) {
    string memory path = _writeLane(name, bpsBlock);
    lane = harness.readLane(path);
    vm.removeFile(path);
  }

  function _expectLaneRevert(
    string memory name,
    string memory bpsBlock,
    string memory reasonFragment
  ) internal {
    string memory path = _writeLane(name, bpsBlock);
    try harness.readLane(path) {
      fail("expected the lane to be rejected");
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), reason);
    }
    vm.removeFile(path);
  }

  function _verifierEntry(
    string memory tag,
    string memory extra
  ) internal pure returns (string memory) {
    string memory zero = "0x0000000000000000000000000000000000000000";
    return string.concat(
      '{"versionTag":"',
      tag,
      '","allowedFinality":{},"storageLocations":[],"signatureConfig":{"threshold":0,"signers":[]},',
      '"roles":{"owner":"',
      zero,
      '","storageLocationsAdmin":"',
      zero,
      '","allowlistAdmin":"',
      zero,
      '","feeAggregator":"',
      zero,
      '"}',
      extra,
      "}"
    );
  }

  function _resolverAndFactory() internal pure returns (string memory) {
    return string.concat(
      '"resolver":{"roles":{"owner":"0x0000000000000000000000000000000000000000","feeAggregator":"0x0000000000000000000000000000000000000000"}},',
      '"factory":{"roles":{"owner":"0x0000000000000000000000000000000000000000","allowlist":[]}}'
    );
  }
}
