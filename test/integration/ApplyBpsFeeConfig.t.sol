// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ApplyBpsFeeConfig} from "../../script/configure/ApplyBpsFeeConfig.s.sol";
import {DriftCheck} from "../../script/governance/DriftCheck.s.sol";
import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BpsFeeConfig} from "../../src/bps/BpsFeeConfig.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {Test} from "forge-std/Test.sol";

/// @notice ApplyBpsFeeConfig's call builder and DriftCheck.checkBpsFees against a real
///         BpsFeeCommitteeVerifier owned by this test, with the remote chain config for
///         DEST already applied (the documented precondition).
contract ApplyBpsFeeConfigTest is Test {
  string internal constant ALIAS = "local_chain";
  bytes4 internal constant TAG = 0x00020001;
  bytes4 internal constant OTHER_TAG = 0x00010001;
  uint64 internal constant DEST = 2222;
  uint64 internal constant UNCONFIGURED_DEST = 3333;
  address internal constant ROUTER = address(0x9001);
  address internal constant TOKEN = address(0x7001);
  address internal constant OTHER_TOKEN = address(0x7002);

  ApplyBpsFeeConfig internal script;
  DriftCheck internal drift;
  BpsFeeCommitteeVerifier internal bps;
  MockPriceAdapter internal adapter;
  MockPriceAdapter internal otherAdapter;

  function setUp() public {
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://aggregator.example/ccv";
    bps = new BpsFeeCommitteeVerifier(
      CommitteeVerifier.DynamicConfig({feeAggregator: address(0xFEE), allowlistAdmin: address(this)}),
      storageLocations,
      address(0xdEaD),
      TAG
    );
    BaseVerifier.RemoteChainConfigArgs[] memory remote = new BaseVerifier.RemoteChainConfigArgs[](1);
    remote[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(ROUTER),
      remoteChainSelector: DEST,
      allowlistEnabled: false,
      feeUSDCents: 50,
      gasForVerification: 200_000,
      payloadSizeBytes: 0
    });
    bps.applyRemoteChainConfigUpdates(remote);

    adapter = new MockPriceAdapter(TOKEN, 400_000);
    otherAdapter = new MockPriceAdapter(OTHER_TOKEN, 100);
    script = new ApplyBpsFeeConfig();
    drift = new DriftCheck();
  }

  // ===========================================================================
  //  callsFor
  // ===========================================================================

  function test_callsFor_stagesAdaptersFeeAndStrictSwitchInOrder() public view {
    BaseScript.Call[] memory calls = _calls(_lanes(_fee(true, 5, 50, 5000)), true);

    assertEq(calls.length, 3, "adapters + one fee config + requireAllTokensPriced");
    assertEq(bytes4(calls[0].data), BpsFeeCommitteeVerifier.setPriceAdapters.selector, "adapters first");
    assertEq(bytes4(calls[1].data), BpsFeeCommitteeVerifier.setFeeConfig.selector);
    assertEq(bytes4(calls[2].data), BpsFeeCommitteeVerifier.setRequireAllTokensPriced.selector, "strict switch last");
    for (uint256 i = 0; i < calls.length; ++i) {
      assertEq(calls[i].to, address(bps));
    }
  }

  function test_callsFor_appliedCallsReachTheDeclaredState() public {
    BpsFeeConfig memory fee = _fee(true, 5, 50, 5000);
    _execute(_calls(_lanes(fee), true));

    assertEq(address(bps.getPriceAdapter(TOKEN)), address(adapter));
    assertEq(address(bps.getPriceAdapter(OTHER_TOKEN)), address(otherAdapter));
    assertTrue(BpsConfigLib.feeConfigEq(bps.getFeeConfig(DEST), fee));
    assertTrue(bps.requireAllTokensPriced());
  }

  function test_callsFor_rerunIsANoOp() public {
    BpsConfigLib.LaneBpsFee[] memory lanes = _lanes(_fee(true, 5, 50, 5000));
    _execute(_calls(lanes, true));
    assertEq(_calls(lanes, true).length, 0, "everything already current");
  }

  function test_callsFor_registersOnlyTheAdaptersNotYetCurrent() public {
    bps.setPriceAdapter(TOKEN, adapter);
    (address[] memory tokens,) = script.adaptersToRegister(address(bps), _adapters());
    assertEq(tokens.length, 1);
    assertEq(tokens[0], OTHER_TOKEN);
  }

  /// @dev A replaced adapter (ALLOW_ADAPTER_REPLACE) re-points the verifier.
  function test_callsFor_repointsAReplacedAdapter() public {
    MockPriceAdapter old = new MockPriceAdapter(TOKEN, 1);
    bps.setPriceAdapter(TOKEN, old);
    (address[] memory tokens,) = script.adaptersToRegister(address(bps), _adapters());
    assertEq(tokens.length, 2, "TOKEN points at the old adapter, so it is restaged");
  }

  function test_callsFor_ignoresLanesFromAnotherChainOrTag() public view {
    BpsConfigLib.LaneBpsFee[] memory lanes = new BpsConfigLib.LaneBpsFee[](2);
    lanes[0] = _lane("other-chain", "zz-scratch-other", DEST, TAG, _fee(true, 5, 50, 5000));
    lanes[1] = _lane("other-tag", ALIAS, DEST, OTHER_TAG, _fee(true, 5, 50, 5000));
    BaseScript.Call[] memory calls =
      script.callsFor(address(bps), new Types.PriceAdapterDeployment[](0), lanes, ALIAS, TAG, false);
    assertEq(calls.length, 0);
  }

  /// @dev Absent bpsFeeConfig means disabled; a disabled policy needs no remote config.
  function test_callsFor_disablesAPolicyTheLaneNoLongerDeclares() public {
    _execute(_calls(_lanes(_fee(true, 5, 50, 5000)), false));
    BaseScript.Call[] memory calls = _calls(_lanes(_fee(false, 0, 0, 0)), false);
    assertEq(calls.length, 1);
    _execute(calls);
    assertFalse(bps.getFeeConfig(DEST).enabled);
  }

  function test_callsFor_rejectsAnEnabledPolicyBeforeApplyRemoteConfig() public {
    BpsConfigLib.LaneBpsFee[] memory lanes = new BpsConfigLib.LaneBpsFee[](1);
    lanes[0] = _lane("no-remote", ALIAS, UNCONFIGURED_DEST, TAG, _fee(true, 5, 50, 5000));
    vm.expectRevert(
      bytes(
        "ApplyBpsFeeConfig: lane no-remote enables a bps fee, but the verifier has no remote chain config (router) for its destination - run make apply-remote-config CHAIN=local_chain TAG=0x00020001 first (and execute it)"
      )
    );
    script.callsFor(address(bps), new Types.PriceAdapterDeployment[](0), lanes, ALIAS, TAG, false);
  }

  function test_callsFor_rejectsOutOfBoundsPolicy() public {
    vm.expectRevert(bytes("ApplyBpsFeeConfig: lane lane bpsFeeConfig: feeBps must be <= 10000 (100%)"));
    script.callsFor(
      address(bps), new Types.PriceAdapterDeployment[](0), _lanes(_fee(true, 10_001, 1, 1)), ALIAS, TAG, false
    );
  }

  function test_callsFor_rejectsAnAdapterPricingAnotherToken() public {
    Types.PriceAdapterDeployment[] memory adapters = new Types.PriceAdapterDeployment[](1);
    adapters[0].addr = address(otherAdapter); // prices OTHER_TOKEN
    adapters[0].args.token = TOKEN;
    vm.expectRevert();
    script.adaptersToRegister(address(bps), adapters);
  }

  function test_callsFor_rejectsACodelessAdapter() public {
    Types.PriceAdapterDeployment[] memory adapters = new Types.PriceAdapterDeployment[](1);
    adapters[0].addr = address(0xC0DE1E55);
    adapters[0].args.token = TOKEN;
    vm.expectRevert();
    script.adaptersToRegister(address(bps), adapters);
  }

  /// @dev The point of feeConfigError: it accepts exactly what setFeeConfig accepts, so
  ///      validate-config and the script reject a policy before a batch would revert.
  function testFuzz_feeConfigError_matchesTheContract(
    bool enabled,
    uint16 feeBps,
    uint16 minFee,
    uint16 cap
  ) public {
    BpsFeeConfig memory fee = _fee(enabled, feeBps, minFee, cap);
    bool acceptedOffChain = bytes(BpsConfigLib.feeConfigError(fee)).length == 0;
    (bool acceptedOnChain,) = address(bps).call(abi.encodeCall(BpsFeeCommitteeVerifier.setFeeConfig, (DEST, fee)));
    assertEq(acceptedOffChain, acceptedOnChain);
  }

  // ===========================================================================
  //  DriftCheck.checkBpsFees
  // ===========================================================================

  function test_drift_cleanAfterApplying() public {
    BpsConfigLib.LaneBpsFee[] memory lanes = _lanes(_fee(true, 5, 50, 5000));
    _execute(_calls(lanes, true));
    assertEq(drift.checkBpsFees(_record("BpsFeeCommitteeVerifier"), lanes, _policies(true)), 0);
  }

  function test_drift_beforeApplying_countsEachSetting() public view {
    // two unregistered adapters + one fee config + requireAllTokensPriced
    assertEq(
      drift.checkBpsFees(_record("BpsFeeCommitteeVerifier"), _lanes(_fee(true, 5, 50, 5000)), _policies(true)), 4
    );
  }

  function test_drift_feeConfigField() public {
    BpsConfigLib.LaneBpsFee[] memory lanes = _lanes(_fee(true, 5, 50, 5000));
    _execute(_calls(lanes, false));
    lanes[0].fee.capUSDCents = 6000;
    assertEq(drift.checkBpsFees(_record("BpsFeeCommitteeVerifier"), lanes, _policies(false)), 1);
  }

  function test_drift_adapterPointsElsewhere() public {
    BpsConfigLib.LaneBpsFee[] memory lanes = _lanes(_fee(false, 0, 0, 0));
    _execute(_calls(lanes, false));
    bps.setPriceAdapter(TOKEN, new MockPriceAdapter(TOKEN, 1));
    assertEq(drift.checkBpsFees(_record("BpsFeeCommitteeVerifier"), lanes, _policies(false)), 1);
  }

  function test_drift_requireAllTokensPriced() public {
    BpsConfigLib.LaneBpsFee[] memory lanes = _lanes(_fee(false, 0, 0, 0));
    _execute(_calls(lanes, false));
    assertEq(drift.checkBpsFees(_record("BpsFeeCommitteeVerifier"), lanes, _policies(true)), 1);
  }

  /// @dev A policy enabled on-chain that the lane no longer declares is drift.
  function test_drift_onChainPolicyNoLaneDeclares() public {
    _execute(_calls(_lanes(_fee(true, 5, 50, 5000)), false));
    assertEq(drift.checkBpsFees(_record("BpsFeeCommitteeVerifier"), _lanes(_fee(false, 0, 0, 0)), _policies(false)), 1);
  }

  /// @dev The standard path: a stock verifier with no bps declarations is never read.
  function test_drift_stockVerifierWithoutBpsSettingsIsSkipped() public view {
    assertEq(drift.checkBpsFees(_record("CommitteeVerifier"), _lanes(_fee(false, 0, 0, 0)), _policies(false)), 0);
  }

  function test_drift_bpsSettingsDeclaredForAStockVerifier() public view {
    assertEq(drift.checkBpsFees(_record("CommitteeVerifier"), _lanes(_fee(true, 5, 50, 5000)), _policies(true)), 2);
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  function _fee(
    bool enabled,
    uint16 feeBps,
    uint16 minFee,
    uint16 cap
  ) internal pure returns (BpsFeeConfig memory) {
    return BpsFeeConfig({enabled: enabled, feeBps: feeBps, minFeeUSDCents: minFee, capUSDCents: cap});
  }

  function _lane(
    string memory name,
    string memory sourceAlias,
    uint64 dest,
    bytes4 tag,
    BpsFeeConfig memory fee
  ) internal pure returns (BpsConfigLib.LaneBpsFee memory) {
    return
      BpsConfigLib.LaneBpsFee({laneName: name, sourceAlias: sourceAlias, destSelector: dest, versionTag: tag, fee: fee});
  }

  function _lanes(
    BpsFeeConfig memory fee
  ) internal pure returns (BpsConfigLib.LaneBpsFee[] memory lanes) {
    lanes = new BpsConfigLib.LaneBpsFee[](1);
    lanes[0] = _lane("lane", ALIAS, DEST, TAG, fee);
  }

  function _adapters() internal view returns (Types.PriceAdapterDeployment[] memory adapters) {
    adapters = new Types.PriceAdapterDeployment[](2);
    adapters[0].addr = address(adapter);
    adapters[0].args.token = TOKEN;
    adapters[1].addr = address(otherAdapter);
    adapters[1].args.token = OTHER_TOKEN;
  }

  function _policies(
    bool requireAll
  ) internal pure returns (BpsConfigLib.VerifierBpsPolicy[] memory policies) {
    policies = new BpsConfigLib.VerifierBpsPolicy[](1);
    policies[0] = BpsConfigLib.VerifierBpsPolicy({versionTag: TAG, requireAllTokensPriced: requireAll});
  }

  function _record(
    string memory contractName
  ) internal view returns (Types.Deployment memory deployment) {
    deployment.aliasName = ALIAS;
    deployment.verifiers = new Types.VerifierDeployment[](1);
    deployment.verifiers[0].versionTag = TAG;
    deployment.verifiers[0].addr = address(bps);
    deployment.verifiers[0].contractName = contractName;
    deployment.priceAdapters = _adapters();
  }

  function _calls(
    BpsConfigLib.LaneBpsFee[] memory lanes,
    bool requireAll
  ) internal view returns (BaseScript.Call[] memory) {
    return script.callsFor(address(bps), _adapters(), lanes, ALIAS, TAG, requireAll);
  }

  /// @dev msg.sender is this test, the verifier's owner.
  function _execute(
    BaseScript.Call[] memory calls
  ) internal {
    for (uint256 i = 0; i < calls.length; ++i) {
      (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
      assertTrue(ok, string(ret));
    }
  }
}
