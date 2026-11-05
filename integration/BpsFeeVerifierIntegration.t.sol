// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { BpsFeeCommitteeVerifier } from "../../src/BpsFeeCommitteeVerifier.sol";
import { BpsFeeConfig } from "../../src/config/BpsFeeConfig.sol";
import { IPriceAdapter } from "../../src/oracle/IPriceAdapter.sol";
import { WstETHUSDPriceAdapter } from "../../src/oracle/WstETHUSDPriceAdapter.sol";
import { PriceFeedLib } from "../../src/oracle/PriceFeedLib.sol";

import { CommitteeVerifier } from "@chainlink-ccip/ccvs/CommitteeVerifier.sol";
import { BaseVerifier } from "@chainlink-ccip/ccvs/components/BaseVerifier.sol";
import { IRouter } from "@chainlink-ccip/interfaces/IRouter.sol";
import { Client } from "@chainlink-ccip/libraries/Client.sol";

import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";
import { MockWstETH } from "../mocks/MockWstETH.sol";

/// @notice Integration tests: the REAL wstETH price adapter registered behind
///         the verifier, exercised end-to-end through getFee. This crosses the
///         adapter<->verifier seam that the unit tests (which use a linear
///         MockPriceAdapter) do not, catching decimals/unit mismatches and
///         pinning the fail-closed-on-stale behavior. Also includes a decimals
///         matrix and a sub-cent rounding case.
contract BpsFeeVerifierIntegrationTest is Test {
  BpsFeeCommitteeVerifier internal verifier;

  // wstETH #1: wstETH/USD = $4800 (8 dec) -> 480_000 cents / token.
  MockWstETH internal wstETH1;
  MockAggregatorV3 internal feed1;
  WstETHUSDPriceAdapter internal adapter1;
  address internal token1; // == address(wstETH1)

  // wstETH #2: wstETH/USD = $500 (8 dec) -> 50_000 cents / token.
  MockWstETH internal wstETH2;
  MockAggregatorV3 internal feed2;
  WstETHUSDPriceAdapter internal adapter2;
  address internal token2; // == address(wstETH2)

  uint64 internal constant DEST = 1;
  uint16 internal constant FLAT_FEE = 25;
  uint32 internal constant GAS = 90_000;
  uint16 internal constant PAYLOAD = 256;

  uint16 internal constant FEE_BPS = 5; // 0.05%
  uint16 internal constant MIN_CENTS = 10;
  uint16 internal constant CAP_CENTS = 1000;

  uint256 internal constant MAX_STALENESS = 1 hours;
  uint256 internal constant START_TS = 1_000_000;

  function setUp() public {
    vm.warp(START_TS);

    CommitteeVerifier.DynamicConfig memory dc =
      CommitteeVerifier.DynamicConfig({ feeAggregator: makeAddr("agg"), allowlistAdmin: makeAddr("allowlistAdmin") });
    verifier = new BpsFeeCommitteeVerifier(dc, new string[](0), makeAddr("rmn"), bytes4(uint32(1)));

    BaseVerifier.RemoteChainConfigArgs[] memory args = new BaseVerifier.RemoteChainConfigArgs[](1);
    args[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(makeAddr("router")),
      remoteChainSelector: DEST,
      allowlistEnabled: false,
      feeUSDCents: FLAT_FEE,
      gasForVerification: GAS,
      payloadSizeBytes: PAYLOAD
    });
    verifier.applyRemoteChainConfigUpdates(args);
    verifier.setFeeConfig(
      DEST, BpsFeeConfig({ feeBps: FEE_BPS, minFeeUSDCents: MIN_CENTS, capUSDCents: CAP_CENTS, enabled: true })
    );

    // Real adapters backed by mock oracles.
    wstETH1 = new MockWstETH();
    feed1 = new MockAggregatorV3(8, 4800e8, block.timestamp);
    adapter1 = new WstETHUSDPriceAdapter(address(wstETH1), address(feed1), MAX_STALENESS);
    token1 = address(wstETH1);

    wstETH2 = new MockWstETH();
    feed2 = new MockAggregatorV3(8, 500e8, block.timestamp);
    adapter2 = new WstETHUSDPriceAdapter(address(wstETH2), address(feed2), MAX_STALENESS);
    token2 = address(wstETH2);

    verifier.setPriceAdapter(token1, IPriceAdapter(address(adapter1)));
    verifier.setPriceAdapter(token2, IPriceAdapter(address(adapter2)));
  }

  // --- helpers ---------------------------------------------------------------

  function _emptyMsg() internal pure returns (Client.EVM2AnyMessage memory m) {
    m.receiver = "";
    m.data = "";
    m.tokenAmounts = new Client.EVMTokenAmount[](0);
    m.feeToken = address(0);
    m.extraArgs = "";
  }

  function _msg1(address token, uint256 amount) internal pure returns (Client.EVM2AnyMessage memory m) {
    m = _emptyMsg();
    m.tokenAmounts = new Client.EVMTokenAmount[](1);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: token, amount: amount });
  }

  function _msg2(address t0, uint256 a0, address t1, uint256 a1)
    internal
    pure
    returns (Client.EVM2AnyMessage memory m)
  {
    m = _emptyMsg();
    m.tokenAmounts = new Client.EVMTokenAmount[](2);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: t0, amount: a0 });
    m.tokenAmounts[1] = Client.EVMTokenAmount({ token: t1, amount: a1 });
  }

  function _fee(Client.EVM2AnyMessage memory m) internal view returns (uint16 f) {
    (f,,) = verifier.getFee(DEST, m, "", bytes4(0));
  }

  // --- end-to-end via the real adapter ---------------------------------------

  function test_integration_singleWstETH() public view {
    // 1 wstETH -> $4800 -> 480_000 cents; 480_000 * 5 / 10_000 = 240 cents.
    assertEq(_fee(_msg1(token1, 1e18)), 240);
  }

  function test_integration_capApplied() public view {
    // 100 wstETH -> 48,000,000 cents; * 5 / 10_000 = 24_000 -> cap 1000.
    assertEq(_fee(_msg1(token1, 100e18)), CAP_CENTS);
  }

  function test_integration_multiToken_realAdapters() public view {
    // token1 1e18 -> 480_000, token2 1e18 -> 50_000; sum 530_000; * 5 / 10_000 = 265.
    assertEq(_fee(_msg2(token1, 1e18, token2, 1e18)), 265);
  }

  // --- sub-cent rounding ------------------------------------------------------

  function test_integration_subCentFee_roundsDownToFloor() public view {
    // 0.001 wstETH -> 480 cents value; 480 * 5 / 10_000 = 0.24 -> 0 -> floor.
    assertEq(_fee(_msg1(token1, 1e15)), MIN_CENTS);
  }

  // --- deal with unhealthy oracle (contrast with unpriced->zero) ---------

  function test_integration_staleFeed_strictReverts() public {
    verifier.setRequireAllTokensPriced(true); // fail-closed posture
    vm.warp(block.timestamp + MAX_STALENESS + 1);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.StalePrice.selector, address(feed1), START_TS, MAX_STALENESS));
    verifier.getFee(DEST, _msg1(token1, 1e18), "", bytes4(0));
  }

  function test_integration_nonPositiveFeed_strictReverts() public {
    verifier.setRequireAllTokensPriced(true); // fail-closed posture
    feed1.setAnswer(0);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.NonPositivePrice.selector, address(feed1), int256(0)));
    verifier.getFee(DEST, _msg1(token1, 1e18), "", bytes4(0));
  }

  function test_integration_staleFeed_defaultDegradesToFloor() public {
    // Default fail-open: a stale real feed degrades token1 to zero value, so a
    // single-token message clamps to the floor and getFee does NOT revert.
    vm.warp(block.timestamp + MAX_STALENESS + 1);
    assertEq(_fee(_msg1(token1, 1e18)), MIN_CENTS);
  }

  function test_integration_staleFeed_defaultStillPricesHealthyToken() public {
    // token1's feed stale, token2's fresh: message still prices from token2.
    // token2 1e18 -> 50_000; 50_000 * 5 / 10_000 = 25 cents. No revert.
    vm.warp(block.timestamp + MAX_STALENESS + 1);
    feed2.setUpdatedAt(block.timestamp); // refresh only token2's feed
    assertEq(_fee(_msg2(token1, 1e18, token2, 1e18)), 25);
  }

  // --- decimals matrix (adapter math across feed decimals) --------------------

  function test_integration_decimalsMatrix() public {
    uint8[3] memory decs = [uint8(6), uint8(8), uint8(18)];
    for (uint256 i = 0; i < decs.length; ++i) {
      uint8 d = decs[i];
      // $4800 / wstETH expressed at `d` decimals.
      MockAggregatorV3 f = new MockAggregatorV3(d, int256(4800 * (10 ** uint256(d))), block.timestamp);
      WstETHUSDPriceAdapter a = new WstETHUSDPriceAdapter(address(wstETH1), address(f), MAX_STALENESS);
      // 1 wstETH = $4800 = 480_000 cents, regardless of feed decimals.
      assertEq(a.getValueInUSDCents(1e18), 480_000, "decimals matrix");
    }
  }
}
