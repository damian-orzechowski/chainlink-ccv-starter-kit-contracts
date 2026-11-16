// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DriftCheck} from "../../script/governance/DriftCheck.s.sol";
import {SnapshotOperator} from "../../script/governance/SnapshotOperator.s.sol";
import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {WstETHUSDL2PriceAdapter} from "../../src/price-adapters/WstETHUSDL2PriceAdapter.sol";
import {WstETHUSDPriceAdapter} from "../../src/price-adapters/WstETHUSDPriceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";
import {MockWstETH} from "../mocks/MockWstETH.sol";
import {CommitteeVerifierSetup} from "./CommitteeVerifierSetup.t.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title SnapshotOperatorBpsTest
/// @notice The BpsFeeCommitteeVerifier extras of SnapshotOperator: `priceAdapters[]` rebuilt
///         from chain and `requireAllTokensPriced` per bps verifier, so promoting a snapshot
///         keeps both instead of deleting them.
/// @dev Forge runs tests concurrently against one filesystem: every writing test uses its
///      own alias, so its snapshot path is its own.
contract SnapshotOperatorBpsTest is CommitteeVerifierSetup {
  string internal constant ALIAS = "snapshot_bps_chain";
  bytes4 internal constant BPS_TAG = 0x00020001;
  uint256 internal constant L1_STALENESS = 90_000;
  uint256 internal constant RATE_STALENESS = 86_400;
  uint256 internal constant USD_STALENESS = 3600;
  uint256 internal constant GRACE = 3600;

  SnapshotOperator internal script;
  BpsFeeCommitteeVerifier internal bps;
  address internal l1Token;
  address internal l2Token;
  address internal l1UsdFeed;
  address internal l2RateFeed;
  address internal l2UsdFeed;
  address internal sequencerFeed;
  WstETHUSDPriceAdapter internal l1Adapter;
  WstETHUSDL2PriceAdapter internal l2Adapter;

  function setUp() public virtual override {
    super.setUp();
    script = new SnapshotOperator();

    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://aggregator.example/ccv";
    bps = new BpsFeeCommitteeVerifier(
      CommitteeVerifier.DynamicConfig({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: address(this)}),
      storageLocations,
      RMN,
      BPS_TAG
    );

    l1Token = address(new MockWstETH());
    l2Token = address(new MockWstETH());
    l1UsdFeed = address(new MockAggregatorV3(8, 4000e8, block.timestamp));
    l2RateFeed = address(new MockAggregatorV3(18, 1.2e18, block.timestamp));
    l2UsdFeed = address(new MockAggregatorV3(8, 3000e8, block.timestamp));
    sequencerFeed = address(new MockAggregatorV3(0, 0, block.timestamp));
    l1Adapter = new WstETHUSDPriceAdapter(l1Token, l1UsdFeed, L1_STALENESS);
    l2Adapter =
      new WstETHUSDL2PriceAdapter(l2Token, l2RateFeed, l2UsdFeed, RATE_STALENESS, USD_STALENESS, sequencerFeed, GRACE);
  }

  // ===========================================================================
  //  priceAdapters[]
  // ===========================================================================

  function test_snapshot_describesRegisteredAdaptersOfBothKinds() public {
    _registerBoth();
    Types.OperatorConfig memory op = script.snapshot(_deployment());

    assertEq(op.priceAdapters.length, 2, "one entry per recorded token");
    _assertL1(op.priceAdapters[0], L1_STALENESS);
    _assertL2(op.priceAdapters[1]);
  }

  /// @dev Deployed by deploy-price-adapter but apply-bps-config not yet run: the
  ///      record's adapter is still the declaration to keep.
  function test_snapshot_describesARecordedButUnregisteredAdapter() public view {
    Types.OperatorConfig memory op = script.snapshot(_deployment());
    assertEq(op.priceAdapters.length, 2);
    _assertL1(op.priceAdapters[0], L1_STALENESS);
    _assertL2(op.priceAdapters[1]);
  }

  /// @dev Declared, deploy-price-adapter not yet run: nothing on chain to read, and
  ///      dropping it would undo the declaration the next deploy needs.
  function test_snapshot_carriesOverADeclaredButUndeployedAdapter() public view {
    Types.PriceAdapterConfig[] memory declared = new Types.PriceAdapterConfig[](1);
    declared[0] = _l1Config(address(0x7777), 1234);
    Types.OperatorConfig memory op = script.snapshot(_deploymentWithoutRecordedAdapters(), declared);

    assertEq(op.priceAdapters.length, 1);
    assertEq(op.priceAdapters[0].token, address(0x7777));
    assertEq(op.priceAdapters[0].usdMaxStaleness, 1234, "the declared entry, verbatim");
  }

  /// @dev An adapter registered by hand (no record) is still found through the token the
  ///      operator file declares, and chain wins over the declared values.
  function test_snapshot_readsAHandRegisteredAdapterThroughTheDeclaredToken() public {
    bps.setPriceAdapter(l1Token, l1Adapter);
    Types.PriceAdapterConfig[] memory declared = new Types.PriceAdapterConfig[](1);
    declared[0] = _l1Config(l1Token, 1234);
    Types.OperatorConfig memory op = script.snapshot(_deploymentWithoutRecordedAdapters(), declared);

    assertEq(op.priceAdapters.length, 1);
    _assertL1(op.priceAdapters[0], L1_STALENESS);
  }

  /// @dev Declared tokens keep their order; recorded-only tokens follow.
  function test_snapshot_ordersDeclaredTokensFirst() public view {
    Types.PriceAdapterConfig[] memory declared = new Types.PriceAdapterConfig[](1);
    declared[0] = _l2Config(l2Token);
    Types.OperatorConfig memory op = script.snapshot(_deployment(), declared);

    assertEq(op.priceAdapters.length, 2);
    assertEq(op.priceAdapters[0].token, l2Token, "declared first");
    assertEq(op.priceAdapters[1].token, l1Token, "then the recorded-only token");
  }

  function test_snapshot_describesTheRegisteredAdapterOverTheRecordedOne() public {
    WstETHUSDPriceAdapter replacement = new WstETHUSDPriceAdapter(l1Token, l1UsdFeed, 7200);
    bps.setPriceAdapter(l1Token, replacement);
    Types.OperatorConfig memory op = script.snapshot(_deployment());
    _assertL1(op.priceAdapters[0], 7200);
  }

  function test_snapshot_undescribableAdapter_keepsTheDeclaredEntry() public {
    Types.Deployment memory deployment = _deploymentWithAdapter(address(new MockPriceAdapter(l1Token, 1)));
    Types.PriceAdapterConfig[] memory declared = new Types.PriceAdapterConfig[](1);
    declared[0] = _l1Config(l1Token, 1234);
    Types.OperatorConfig memory op = script.snapshot(deployment, declared);

    assertEq(op.priceAdapters.length, 1);
    assertEq(op.priceAdapters[0].usdMaxStaleness, 1234, "declared entry carried over");
  }

  function test_snapshot_undescribableAdapter_undeclared_isLeftOut() public {
    Types.Deployment memory deployment = _deploymentWithAdapter(address(new MockPriceAdapter(l1Token, 1)));
    assertEq(script.snapshot(deployment).priceAdapters.length, 0, "nothing the schema can hold");
  }

  function test_describeAdapter_rejectsUnknownAndCodeless() public {
    (bool known, Types.PriceAdapterConfig memory c) = script.describeAdapter(address(new MockPriceAdapter(l1Token, 1)));
    assertFalse(known, "neither adapter type");
    assertEq(c.contractName, "", "nothing described");
    (known, c) = script.describeAdapter(address(0xC0DE1E55));
    assertFalse(known, "no code");
    assertEq(c.token, address(0), "nothing described");
  }

  function test_snapshot_stockOnlyChain_hasNoAdaptersOrPolicies() public view {
    Types.Deployment memory deployment = _deploymentWithoutRecordedAdapters();
    deployment.verifiers = _verifiersOf(address(verifier));
    assertEq(script.snapshot(deployment).priceAdapters.length, 0);
    assertEq(script.snapshotBpsPolicies(deployment).length, 0);
  }

  // ===========================================================================
  //  requireAllTokensPriced
  // ===========================================================================

  function test_snapshotBpsPolicies_readsOnlyBpsVerifiers() public {
    bps.setRequireAllTokensPriced(true);
    BpsConfigLib.VerifierBpsPolicy[] memory policies = script.snapshotBpsPolicies(_deployment());

    assertEq(policies.length, 1, "the stock verifier has no such setting");
    assertEq(policies[0].versionTag, BPS_TAG);
    assertTrue(policies[0].requireAllTokensPriced);
  }

  // ===========================================================================
  //  written file
  // ===========================================================================

  /// @dev The promotion path is a copy, so the written file must load under the same
  ///      loaders that read config/operator/chains/ and give back what was snapshotted.
  function test_writeSnapshot_roundTripsAdaptersAndPolicy() public {
    _registerBoth();
    bps.setRequireAllTokensPriced(true);
    Types.Deployment memory deployment = _deployment();
    string memory path = script.writeSnapshot(
      string.concat(ALIAS, "-roundtrip"), script.snapshot(deployment), script.snapshotBpsPolicies(deployment)
    );

    Types.OperatorConfig memory reloaded = ConfigLib.readOperatorByPath(path);
    assertEq(reloaded.priceAdapters.length, 2);
    _assertL1(reloaded.priceAdapters[0], L1_STALENESS);
    _assertL2(reloaded.priceAdapters[1]);

    BpsConfigLib.VerifierBpsPolicy[] memory policies = BpsConfigLib.readVerifierPoliciesByPath(path);
    assertTrue(BpsConfigLib.requireAllTokensPricedFor(policies, BPS_TAG), "bps verifier's flag");

    string memory json = vm.readFile(path);
    assertFalse(vm.keyExistsJson(json, ".verifiers[0].requireAllTokensPriced"), "not written on a stock verifier");
    assertTrue(vm.keyExistsJson(json, ".verifiers[1].requireAllTokensPriced"), "written on the bps verifier");
  }

  /// @dev A false flag is written too: the snapshot states the bps verifier's posture.
  function test_writeSnapshot_writesAFalsePolicyExplicitly() public {
    Types.Deployment memory deployment = _deployment();
    string memory path = script.writeSnapshot(
      string.concat(ALIAS, "-false"), script.snapshot(deployment), script.snapshotBpsPolicies(deployment)
    );
    string memory json = vm.readFile(path);
    assertTrue(vm.keyExistsJson(json, ".verifiers[1].requireAllTokensPriced"));
    assertFalse(vm.parseJsonBool(json, ".verifiers[1].requireAllTokensPriced"));
  }

  /// @dev Snapshot, promote, drift-check: the bps settings must come back clean.
  function test_snapshotThenDriftCheck_bpsIsClean() public {
    _registerBoth();
    bps.setRequireAllTokensPriced(true);
    Types.Deployment memory deployment = _deployment();
    string memory path = script.writeSnapshot(
      string.concat(ALIAS, "-drift"), script.snapshot(deployment), script.snapshotBpsPolicies(deployment)
    );

    DriftCheck drift = new DriftCheck();
    assertEq(
      drift.checkBpsFees(deployment, new BpsConfigLib.LaneBpsFee[](0), BpsConfigLib.readVerifierPoliciesByPath(path)),
      0,
      "a fresh snapshot must not drift against its source"
    );
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  function _registerBoth() internal {
    bps.setPriceAdapter(l1Token, l1Adapter);
    bps.setPriceAdapter(l2Token, l2Adapter);
  }

  function _deployment() internal view returns (Types.Deployment memory deployment) {
    deployment = _deploymentWithoutRecordedAdapters();
    deployment.priceAdapters = new Types.PriceAdapterDeployment[](2);
    deployment.priceAdapters[0].addr = address(l1Adapter);
    deployment.priceAdapters[0].args = _l1Config(l1Token, L1_STALENESS);
    deployment.priceAdapters[1].addr = address(l2Adapter);
    deployment.priceAdapters[1].args = _l2Config(l2Token);
  }

  function _deploymentWithAdapter(
    address adapter
  ) internal view returns (Types.Deployment memory deployment) {
    deployment = _deploymentWithoutRecordedAdapters();
    deployment.priceAdapters = new Types.PriceAdapterDeployment[](1);
    deployment.priceAdapters[0].addr = adapter;
    deployment.priceAdapters[0].args.token = l1Token;
  }

  /// @dev A stock verifier beside the bps one, so per-verifier handling is exercised.
  function _deploymentWithoutRecordedAdapters() internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.factory = address(factory);
    deployment.resolver = address(resolver);
    deployment.verifiers = new Types.VerifierDeployment[](2);
    deployment.verifiers[0].versionTag = VERSION_TAG;
    deployment.verifiers[0].addr = address(verifier);
    deployment.verifiers[1].versionTag = BPS_TAG;
    deployment.verifiers[1].addr = address(bps);
    deployment.verifiers[1].contractName = BpsConfigLib.BPS_VERIFIER_CONTRACT;
  }

  function _l1Config(
    address token,
    uint256 staleness
  ) internal view returns (Types.PriceAdapterConfig memory c) {
    c.contractName = ConfigLib.L1_PRICE_ADAPTER;
    c.token = token;
    c.usdFeed = l1UsdFeed;
    c.usdMaxStaleness = staleness;
  }

  function _l2Config(
    address token
  ) internal view returns (Types.PriceAdapterConfig memory c) {
    c.contractName = ConfigLib.L2_PRICE_ADAPTER;
    c.token = token;
    c.rateFeed = l2RateFeed;
    c.rateMaxStaleness = RATE_STALENESS;
    c.usdFeed = l2UsdFeed;
    c.usdMaxStaleness = USD_STALENESS;
    c.sequencerUptimeFeed = sequencerFeed;
    c.gracePeriod = GRACE;
  }

  function _assertL1(
    Types.PriceAdapterConfig memory c,
    uint256 staleness
  ) internal view {
    assertEq(c.contractName, ConfigLib.L1_PRICE_ADAPTER, "L1 contract");
    assertEq(c.token, l1Token, "L1 token");
    assertEq(c.usdFeed, l1UsdFeed, "L1 usdFeed");
    assertEq(c.usdMaxStaleness, staleness, "L1 staleness");
    assertEq(c.rateFeed, address(0), "no L2-only fields on L1");
    assertEq(c.gracePeriod, 0, "no L2-only fields on L1");
  }

  function _assertL2(
    Types.PriceAdapterConfig memory c
  ) internal view {
    assertEq(c.contractName, ConfigLib.L2_PRICE_ADAPTER, "L2 contract");
    assertEq(c.token, l2Token, "L2 token");
    assertEq(c.rateFeed, l2RateFeed, "rateFeed");
    assertEq(c.rateMaxStaleness, RATE_STALENESS, "rateMaxStaleness");
    assertEq(c.usdFeed, l2UsdFeed, "usdFeed");
    assertEq(c.usdMaxStaleness, USD_STALENESS, "usdMaxStaleness");
    assertEq(c.sequencerUptimeFeed, sequencerFeed, "sequencerUptimeFeed");
    assertEq(c.gracePeriod, GRACE, "gracePeriod");
  }
}
