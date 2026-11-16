// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RemovePriceAdapter} from "../../script/configure/RemovePriceAdapter.s.sol";
import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IPriceAdapter} from "../../src/price-adapters/IPriceAdapter.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {Test} from "forge-std/Test.sol";

/// @notice RemovePriceAdapter's call builder and record rules against two real
///         BpsFeeCommitteeVerifiers (owned by this test) beside a stock CommitteeVerifier.
contract RemovePriceAdapterTest is Test {
  string internal constant ALIAS = "local_chain";
  bytes4 internal constant STOCK_TAG = 0x00010001;
  bytes4 internal constant TAG = 0x00020001;
  bytes4 internal constant TAG_2 = 0x00020002;
  address internal constant TOKEN = address(0x7001);
  address internal constant OTHER_TOKEN = address(0x7002);

  RemovePriceAdapter internal script;
  CommitteeVerifier internal stock;
  BpsFeeCommitteeVerifier internal bps;
  BpsFeeCommitteeVerifier internal bps2;
  MockPriceAdapter internal adapter;
  MockPriceAdapter internal otherAdapter;

  function setUp() public {
    script = new RemovePriceAdapter();
    stock = new CommitteeVerifier(_dynamicConfig(), _locations(), address(0xdEaD), STOCK_TAG);
    bps = new BpsFeeCommitteeVerifier(_dynamicConfig(), _locations(), address(0xdEaD), TAG);
    bps2 = new BpsFeeCommitteeVerifier(_dynamicConfig(), _locations(), address(0xdEaD), TAG_2);
    adapter = new MockPriceAdapter(TOKEN, 400_000);
    otherAdapter = new MockPriceAdapter(OTHER_TOKEN, 100);

    // As apply-bps-config leaves it: every recorded adapter on every bps verifier.
    bps.setPriceAdapter(TOKEN, adapter);
    bps.setPriceAdapter(OTHER_TOKEN, otherAdapter);
    bps2.setPriceAdapter(TOKEN, adapter);
    bps2.setPriceAdapter(OTHER_TOKEN, otherAdapter);
  }

  // ===========================================================================
  //  callsFor
  // ===========================================================================

  function test_callsFor_unregistersOnEveryBpsVerifier() public view {
    BaseScript.Call[] memory calls = script.callsFor(_deployment(), TOKEN, false);

    assertEq(calls.length, 2, "both bps verifiers; the stock one has no adapters");
    assertEq(calls[0].to, address(bps));
    assertEq(calls[1].to, address(bps2));
    bytes memory expected = abi.encodeCall(BpsFeeCommitteeVerifier.setPriceAdapter, (TOKEN, IPriceAdapter(address(0))));
    assertEq(calls[0].data, expected);
    assertEq(calls[1].data, expected);
  }

  function test_callsFor_appliedCallsUnregisterOnlyThatToken() public {
    _execute(script.callsFor(_deployment(), TOKEN, false));

    assertEq(address(bps.getPriceAdapter(TOKEN)), address(0));
    assertEq(address(bps2.getPriceAdapter(TOKEN)), address(0));
    assertEq(address(bps.getPriceAdapter(OTHER_TOKEN)), address(otherAdapter), "other tokens untouched");
    assertEq(script.callsFor(_deployment(), TOKEN, false).length, 0, "re-run stages nothing");
  }

  function test_callsFor_skipsAVerifierAlreadyWithout() public {
    bps.setPriceAdapter(TOKEN, IPriceAdapter(address(0)));
    BaseScript.Call[] memory calls = script.callsFor(_deployment(), TOKEN, false);
    assertEq(calls.length, 1);
    assertEq(calls[0].to, address(bps2));
  }

  function test_callsFor_refusesUnderRequireAllTokensPriced() public {
    bps2.setRequireAllTokensPriced(true);
    vm.expectRevert(
      bytes(
        string.concat(
          "RemovePriceAdapter: verifier 0x00020002 has requireAllTokensPriced on - unregistering ",
          vm.toString(TOKEN),
          " makes getFee revert for every message carrying it; set ALLOW_UNPRICED=true to proceed anyway"
        )
      )
    );
    script.callsFor(_deployment(), TOKEN, false);
  }

  function test_callsFor_allowUnpricedOverridesTheRefusal() public {
    bps2.setRequireAllTokensPriced(true);
    assertEq(script.callsFor(_deployment(), TOKEN, true).length, 2);
  }

  /// @dev Nothing to unregister means nothing to refuse, even under strict pricing.
  function test_callsFor_strictVerifierWithoutTheTokenIsFine() public {
    bps2.setPriceAdapter(TOKEN, IPriceAdapter(address(0)));
    bps2.setRequireAllTokensPriced(true);
    assertEq(script.callsFor(_deployment(), TOKEN, false).length, 1);
  }

  // ===========================================================================
  //  config first
  // ===========================================================================

  function test_requireUndeclared_refusesWhileDeclared() public {
    Types.OperatorConfig memory op;
    op.priceAdapters = new Types.PriceAdapterConfig[](1);
    op.priceAdapters[0].token = TOKEN;
    vm.expectRevert(
      bytes(
        string.concat(
          "RemovePriceAdapter: config/operator/chains/local_chain.json still declares a priceAdapters entry for token ",
          vm.toString(TOKEN),
          " - delete it first (config is the intent this script applies)"
        )
      )
    );
    script.requireUndeclared(op, ALIAS, TOKEN);
  }

  function test_requireUndeclared_passesOnceDeleted() public view {
    Types.OperatorConfig memory op;
    op.priceAdapters = new Types.PriceAdapterConfig[](1);
    op.priceAdapters[0].token = OTHER_TOKEN;
    script.requireUndeclared(op, ALIAS, TOKEN);
  }

  // ===========================================================================
  //  the record follows the chain
  // ===========================================================================

  /// @dev SAFE mode: the batch is written, not executed, so the record must stay.
  function test_shouldDropRecord_falseWhileAnyVerifierStillPoints() public {
    assertFalse(script.shouldDropRecord(_deployment(), TOKEN), "both still registered");
    bps.setPriceAdapter(TOKEN, IPriceAdapter(address(0)));
    assertFalse(script.shouldDropRecord(_deployment(), TOKEN), "bps2 still registered");
  }

  /// @dev EOA mode (or the re-run after the Safe executed).
  function test_shouldDropRecord_trueOnceUnregisteredEverywhere() public {
    _execute(script.callsFor(_deployment(), TOKEN, false));
    assertTrue(script.shouldDropRecord(_deployment(), TOKEN));
  }

  function test_shouldDropRecord_falseWithNoRecordEntry() public {
    _execute(script.callsFor(_deployment(), TOKEN, false));
    Types.Deployment memory d = _deployment();
    d.priceAdapters = new Types.PriceAdapterDeployment[](0);
    assertFalse(script.shouldDropRecord(d, TOKEN));
  }

  function test_withoutAdapter_dropsOnlyThatTokenAndKeepsOrder() public view {
    Types.Deployment memory d = _deployment();
    d.priceAdapters = new Types.PriceAdapterDeployment[](3);
    d.priceAdapters[0] = _record(OTHER_TOKEN, address(otherAdapter));
    d.priceAdapters[1] = _record(TOKEN, address(adapter));
    d.priceAdapters[2] = _record(address(0x7003), address(0xA3));

    Types.Deployment memory after_ = script.withoutAdapter(d, TOKEN);
    assertEq(after_.priceAdapters.length, 2);
    assertEq(after_.priceAdapters[0].args.token, OTHER_TOKEN);
    assertEq(after_.priceAdapters[1].args.token, address(0x7003));
    assertEq(after_.verifiers.length, 3, "everything else kept");
  }

  // ===========================================================================
  //  helpers
  // ===========================================================================

  function _deployment() internal view returns (Types.Deployment memory d) {
    d.aliasName = ALIAS;
    d.verifiers = new Types.VerifierDeployment[](3);
    d.verifiers[0].versionTag = STOCK_TAG;
    d.verifiers[0].addr = address(stock);
    d.verifiers[1].versionTag = TAG;
    d.verifiers[1].addr = address(bps);
    d.verifiers[1].contractName = BpsConfigLib.BPS_VERIFIER_CONTRACT;
    d.verifiers[2].versionTag = TAG_2;
    d.verifiers[2].addr = address(bps2);
    d.verifiers[2].contractName = BpsConfigLib.BPS_VERIFIER_CONTRACT;
    d.priceAdapters = new Types.PriceAdapterDeployment[](2);
    d.priceAdapters[0] = _record(TOKEN, address(adapter));
    d.priceAdapters[1] = _record(OTHER_TOKEN, address(otherAdapter));
  }

  function _record(
    address token,
    address addr
  ) internal pure returns (Types.PriceAdapterDeployment memory r) {
    r.addr = addr;
    r.args.token = token;
  }

  function _execute(
    BaseScript.Call[] memory calls
  ) internal {
    for (uint256 i = 0; i < calls.length; ++i) {
      (bool ok,) = calls[i].to.call(calls[i].data);
      assertTrue(ok, "staged call reverted");
    }
  }

  function _dynamicConfig() internal view returns (CommitteeVerifier.DynamicConfig memory) {
    return CommitteeVerifier.DynamicConfig({feeAggregator: address(0xFEE), allowlistAdmin: address(this)});
  }

  function _locations() internal pure returns (string[] memory locations) {
    locations = new string[](1);
    locations[0] = "https://aggregator.example/ccv";
  }
}
