// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { WstETHUSDPriceAdapter } from "../src/oracle/WstETHUSDPriceAdapter.sol";
import { PriceFeedLib } from "../src/oracle/PriceFeedLib.sol";

import { MockAggregatorV3 } from "./mocks/MockAggregatorV3.sol";
import { MockWstETH } from "./mocks/MockWstETH.sol";

/// @notice Unit tests for the mainnet wstETH -> USD-cents adapter
///         (wstETH/ETH × ETH/USD).
contract WstETHUSDPriceAdapterTest is Test {
  MockWstETH internal wstETH;
  MockAggregatorV3 internal rateFeed; // wstETH/ETH, 18 decimals
  MockAggregatorV3 internal usdFeed; // ETH/USD, 8 decimals
  WstETHUSDPriceAdapter internal adapter;

  int256 internal constant RATE = 1.2e18; // 1.2 ETH per wstETH, 18 decimals
  int256 internal constant PRICE = 4000e8; // $4000 / ETH, 8 decimals
  uint256 internal constant RATE_MAX = 1 days;
  uint256 internal constant USD_MAX = 1 hours;
  uint256 internal constant START_TS = 1_000_000; // feeds' updatedAt (set at setUp)

  function setUp() public {
    vm.warp(START_TS);
    wstETH = new MockWstETH();
    rateFeed = new MockAggregatorV3(18, RATE, block.timestamp);
    usdFeed = new MockAggregatorV3(8, PRICE, block.timestamp);
    adapter = _deploy(RATE_MAX, USD_MAX);
  }

  /// @dev Deploy helper
  function _deploy(uint256 rateMax, uint256 usdMax) internal returns (WstETHUSDPriceAdapter) {
    return new WstETHUSDPriceAdapter(address(wstETH), address(rateFeed), address(usdFeed), rateMax, usdMax);
  }

  function test_value_oneToken() public view {
    // 1 wstETH -> 1.2 ETH -> 1.2 * $4000 = $4800 = 480_000 cents.
    assertEq(adapter.getValueInUSDCents(1e18), 480_000);
  }

  function test_value_isLinear() public view {
    assertEq(adapter.getValueInUSDCents(0.5e18), 240_000);
    assertEq(adapter.getValueInUSDCents(0), 0);
  }

  function test_value_handlesFeedDecimals() public {
    // 8-decimal rate feed and 18-decimal USD feed give the same answer.
    MockAggregatorV3 rate8 = new MockAggregatorV3(8, 1.2e8, block.timestamp);
    MockAggregatorV3 usd18 = new MockAggregatorV3(18, 4000e18, block.timestamp);
    WstETHUSDPriceAdapter a =
      new WstETHUSDPriceAdapter(address(wstETH), address(rate8), address(usd18), RATE_MAX, USD_MAX);
    assertEq(a.getValueInUSDCents(1e18), 480_000);
  }

  function test_value_tracksBothFeeds() public {
    rateFeed.setAnswer(1.25e18);
    usdFeed.setAnswer(3000e8);
    // 1.25 * $3000 = $3750 = 375_000 cents.
    assertEq(adapter.getValueInUSDCents(1e18), 375_000);
  }

  function test_reverts_whenRateFeedStale() public {
    uint256 staleAt = block.timestamp - (RATE_MAX + 1);
    rateFeed.setUpdatedAt(staleAt);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.StalePrice.selector, address(rateFeed), staleAt, RATE_MAX));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenUsdFeedStale() public {
    // rate feed stays fresh; only the USD feed is stale.
    vm.warp(block.timestamp + USD_MAX + 1);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.StalePrice.selector, address(usdFeed), START_TS, USD_MAX));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenRateNonPositive() public {
    rateFeed.setAnswer(0);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.NonPositivePrice.selector, address(rateFeed), int256(0)));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenUsdNonPositive() public {
    usdFeed.setAnswer(0);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.NonPositivePrice.selector, address(usdFeed), int256(0)));
    adapter.getValueInUSDCents(1e18);
  }

  function test_ctor_reverts_onZeroAddress() public {
    vm.expectRevert(WstETHUSDPriceAdapter.ZeroAddress.selector);
    new WstETHUSDPriceAdapter(address(0), address(rateFeed), address(usdFeed), RATE_MAX, USD_MAX);
    vm.expectRevert(WstETHUSDPriceAdapter.ZeroAddress.selector);
    new WstETHUSDPriceAdapter(address(wstETH), address(0), address(usdFeed), RATE_MAX, USD_MAX);
    vm.expectRevert(WstETHUSDPriceAdapter.ZeroAddress.selector);
    new WstETHUSDPriceAdapter(address(wstETH), address(rateFeed), address(0), RATE_MAX, USD_MAX);
  }

  function test_metadata() public view {
    assertEq(adapter.token(), address(wstETH), "token()");
    assertEq(adapter.tokenDecimals(), 18, "tokenDecimals()");
  }

  function test_ctor_reverts_onWrongTokenDecimals() public {
    wstETH.setDecimals(6);
    vm.expectRevert(abi.encodeWithSelector(WstETHUSDPriceAdapter.UnexpectedTokenDecimals.selector, uint8(18), uint8(6)));
    _deploy(RATE_MAX, USD_MAX);
  }

  function test_ctor_reverts_onZeroRateStaleness() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidMaxStaleness.selector, uint256(0), PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
      )
    );
    _deploy(0, USD_MAX);
  }

  function test_ctor_reverts_onHugeUsdStaleness() public {
    uint256 tooBig = PriceFeedLib.STALENESS_MAX + 1;
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidMaxStaleness.selector, tooBig, PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
      )
    );
    _deploy(RATE_MAX, tooBig);
  }

  function test_ctor_acceptsBoundaryStaleness() public {
    // Inclusive bounds on both feeds are accepted (no revert).
    _deploy(PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX);
    _deploy(PriceFeedLib.STALENESS_MAX, PriceFeedLib.STALENESS_MIN);
  }
}
