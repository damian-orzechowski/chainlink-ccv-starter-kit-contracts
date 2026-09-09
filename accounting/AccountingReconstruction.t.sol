// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { CustomFeeCommitteeVerifier } from "../../src/CustomFeeCommitteeVerifier.sol";
import { CustomFeeConfig } from "../../src/config/CustomFeeConfig.sol";
import { IPriceAdapter } from "../../src/oracle/IPriceAdapter.sol";
import { WstETHUSDPriceAdapter } from "../../src/oracle/WstETHUSDPriceAdapter.sol";

import { CommitteeVerifier } from "@chainlink-ccip/ccvs/CommitteeVerifier.sol";
import { BaseVerifier } from "@chainlink-ccip/ccvs/components/BaseVerifier.sol";
import { IRouter } from "@chainlink-ccip/interfaces/IRouter.sol";
import { Client } from "@chainlink-ccip/libraries/Client.sol";

import { MockPriceAdapter } from "../mocks/MockPriceAdapter.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";
import { MockWstETH } from "../mocks/MockWstETH.sol";

/// @notice Proves the off-chain fee-accounting recipe (docs/ACCOUNTING.md) is
///         sound on-chain:
///           (1) Formula parity — the fee can be reconstructed using ONLY public
///               view getters (getFeeConfig / getPriceAdapter / adapter value /
///               getRemoteChainConfig for the flat fallback) and the documented
///               math, and it matches getFee exactly. If getFee's math ever
///               diverges from the doc, these go red.
///           (2) Reproducibility — getFee is a deterministic pure function of
///               (message, config, oracle state), so replaying an archival
///               eth_call at the send block reproduces the historical charge.

contract AccountingReconstructionTest is Test {
  CustomFeeCommitteeVerifier internal verifier;

  MockWstETH internal wstETH;
  MockAggregatorV3 internal feed; // stETH/USD, 8 decimals
  WstETHUSDPriceAdapter internal adapter1; // real adapter (mutable oracle)
  MockPriceAdapter internal adapter2; // linear, $500 / token

  address internal token1; // == address(wstETH)
  address internal token2 = makeAddr("token2");
  address internal tokenUnpriced = makeAddr("tokenUnpriced");

  uint64 internal constant DEST = 1; // bps enabled
  uint64 internal constant DEST_FLAT = 2; // disabled -> flat fallback

  uint16 internal constant FLAT_FEE = 25;
  uint16 internal constant FEE_BPS = 5;
  uint16 internal constant MIN_CENTS = 10;
  uint16 internal constant CAP_CENTS = 1000;

  uint256 internal constant MAX_STALENESS = 1 hours;
  uint256 internal constant START_TS = 1_000_000;

  function setUp() public {
    vm.warp(START_TS);
    verifier = new CustomFeeCommitteeVerifier(
      CommitteeVerifier.DynamicConfig({ feeAggregator: makeAddr("agg"), allowlistAdmin: makeAddr("admin") }),
      new string[](0),
      makeAddr("rmn"),
      bytes4(uint32(1))
    );
    _setBase(DEST, FLAT_FEE);
    _setBase(DEST_FLAT, FLAT_FEE);
    verifier.setFeeConfig(
      DEST, CustomFeeConfig({ feeBps: FEE_BPS, minFeeUSDCents: MIN_CENTS, capUSDCents: CAP_CENTS, enabled: true })
    );

    wstETH = new MockWstETH(1.2e18);
    feed = new MockAggregatorV3(8, 4000e8, block.timestamp);
    adapter1 = new WstETHUSDPriceAdapter(address(wstETH), address(feed), MAX_STALENESS);
    adapter2 = new MockPriceAdapter(50_000);
    token1 = address(wstETH);

    verifier.setPriceAdapter(token1, IPriceAdapter(address(adapter1)));
    verifier.setPriceAdapter(token2, IPriceAdapter(address(adapter2)));
  }

  function _setBase(uint64 dest, uint16 flatFee) internal {
    BaseVerifier.RemoteChainConfigArgs[] memory a = new BaseVerifier.RemoteChainConfigArgs[](1);
    a[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(makeAddr("router")),
      remoteChainSelector: dest,
      allowlistEnabled: false,
      feeUSDCents: flatFee,
      gasForVerification: 90_000,
      payloadSizeBytes: 256
    });
    verifier.applyRemoteChainConfigUpdates(a);
  }

  // --- message helpers -------------------------------------------------------

  function _empty() internal pure returns (Client.EVM2AnyMessage memory m) {
    m.tokenAmounts = new Client.EVMTokenAmount[](0);
  }

  function _msg1(address t, uint256 a) internal pure returns (Client.EVM2AnyMessage memory m) {
    m = _empty();
    m.tokenAmounts = new Client.EVMTokenAmount[](1);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: t, amount: a });
  }

  function _msg2(address t0, uint256 a0, address t1, uint256 a1)
    internal
    pure
    returns (Client.EVM2AnyMessage memory m)
  {
    m = _empty();
    m.tokenAmounts = new Client.EVMTokenAmount[](2);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: t0, amount: a0 });
    m.tokenAmounts[1] = Client.EVMTokenAmount({ token: t1, amount: a1 });
  }

  // --- on-chain vs off-chain-reconstruction ----------------------------------

  function _onchain(uint64 dest, Client.EVM2AnyMessage memory m) internal view returns (uint16 fee) {
    (fee,,) = verifier.getFee(dest, m, "", bytes4(0));
  }

  /// @dev The documented off-chain reconstruction, using ONLY public getters.
  ///      An indexer implementing ACCOUNTING.md runs exactly this.
  function _reconstruct(uint64 dest, Client.EVM2AnyMessage memory m) internal view returns (uint16) {
    CustomFeeConfig memory c = verifier.getFeeConfig(dest);
    if (!c.enabled) {
      (BaseVerifier.RemoteChainConfigArgs memory rc,) = verifier.getRemoteChainConfig(dest);
      return rc.feeUSDCents; // flat fallback
    }
    uint256 value;
    for (uint256 i = 0; i < m.tokenAmounts.length; ++i) {
      IPriceAdapter a = verifier.getPriceAdapter(m.tokenAmounts[i].token);
      if (address(a) == address(0)) continue; // unpriced -> zero
      value += a.getValueInUSDCents(m.tokenAmounts[i].amount);
    }
    uint256 fee = (value * uint256(c.feeBps)) / 10_000;
    if (fee < c.minFeeUSDCents) fee = c.minFeeUSDCents;
    if (fee > c.capUSDCents) fee = c.capUSDCents;
    return uint16(fee);
  }

  function _assertParity(uint64 dest, Client.EVM2AnyMessage memory m) internal view {
    assertEq(_reconstruct(dest, m), _onchain(dest, m), "reconstruction == getFee");
  }

  // --- (1) formula parity across the case matrix -----------------------------

  function test_parity_single() public view {
    _assertParity(DEST, _msg1(token1, 1e18));
  }

  function test_parity_multiToken() public view {
    _assertParity(DEST, _msg2(token1, 1e18, token2, 3e18));
  }

  function test_parity_unpricedToken() public view {
    _assertParity(DEST, _msg2(token1, 1e18, tokenUnpriced, 5e18));
  }

  function test_parity_cap() public view {
    _assertParity(DEST, _msg1(token1, 100e18));
  }

  function test_parity_floor() public view {
    _assertParity(DEST, _msg1(token1, 1e15));
  }

  function test_parity_noTokens() public view {
    _assertParity(DEST, _empty());
  }

  function test_parity_disabledFlatFallback() public view {
    _assertParity(DEST_FLAT, _msg1(token1, 1e18));
  }

  function testFuzz_parity(uint256 amount) public view {
    amount = bound(amount, 0, 1e33);
    _assertParity(DEST, _msg1(token1, amount));
  }

  // --- (2) reproducibility / determinism -------------------------------------

  function test_repeatedCalls_areEqual() public view {
    assertEq(_onchain(DEST, _msg1(token1, 1e18)), _onchain(DEST, _msg1(token1, 1e18)));
  }

  function test_reproducible_acrossOracleRoundTrip() public {
    uint16 a = _onchain(DEST, _msg1(token1, 1e18));
    feed.setAnswer(8000e8); // price doubles
    uint16 b = _onchain(DEST, _msg1(token1, 1e18));
    feed.setAnswer(4000e8); // restore original round
    uint16 a2 = _onchain(DEST, _msg1(token1, 1e18));

    assertTrue(b != a, "fee tracks oracle state");
    assertEq(a2, a, "restoring the round reproduces the fee");
  }

  function test_callerInvariant() public {
    uint16 a = _onchain(DEST, _msg1(token1, 1e18));
    vm.prank(makeAddr("randomIndexer"));
    (uint16 b,,) = verifier.getFee(DEST, _msg1(token1, 1e18), "", bytes4(0));
    assertEq(a, b, "fee independent of caller");
  }

  function test_timeInvariant_whileFeedFresh() public {
    uint16 a = _onchain(DEST, _msg1(token1, 1e18));
    vm.warp(block.timestamp + 30 minutes); // still within MAX_STALENESS
    uint16 b = _onchain(DEST, _msg1(token1, 1e18));
    assertEq(a, b, "fee independent of time while feed is fresh");
  }
}
