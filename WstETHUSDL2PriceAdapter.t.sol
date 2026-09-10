// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { WstETHUSDL2PriceAdapter } from "../src/oracle/WstETHUSDL2PriceAdapter.sol";
import { PriceFeedLib } from "../src/oracle/PriceFeedLib.sol";

import { MockAggregatorV3 } from "./mocks/MockAggregatorV3.sol";
import { MockWstETH } from "./mocks/MockWstETH.sol";

/// @notice Unit tests for the L2 wstETH -> USD-cents adapter (two-feed composition).
contract WstETHUSDL2PriceAdapterTest is Test {
  MockWstETH internal wstETH; // 18-decimal token
  MockAggregatorV3 internal rateFeed; // wstETH/stETH, 18 decimals
  MockAggregatorV3 internal usdFeed; // stETH/USD, 8 decimals
  WstETHUSDL2PriceAdapter internal adapter;

  int256 internal constant RATE = 1.2e18; // 1.2 stETH per wstETH, 18 decimals
  int256 internal constant PRICE = 4000e8; // $4000 / stETH, 8 decimals
  uint256 internal constant RATE_MAX = 1 days;
  uint256 internal constant USD_MAX = 1 hours;

  function setUp() public {
    vm.warp(1_000_000);
    wstETH = new MockWstETH(1e18);
    rateFeed = new MockAggregatorV3(18, RATE, block.timestamp);
    usdFeed = new MockAggregatorV3(8, PRICE, block.timestamp);
    adapter = new WstETHUSDL2PriceAdapter(address(wstETH), address(rateFeed), address(usdFeed), RATE_MAX, USD_MAX);
  }

  function test_metadata() public view {
    assertEq(adapter.token(), address(wstETH), "token()");
    assertEq(adapter.tokenDecimals(), 18, "tokenDecimals()");
  }

  function test_ctor_reverts_onWrongTokenDecimals() public {
    wstETH.setDecimals(6);
    vm.expectRevert(
      abi.encodeWithSelector(WstETHUSDL2PriceAdapter.UnexpectedTokenDecimals.selector, uint8(18), uint8(6))
    );
    new WstETHUSDL2PriceAdapter(address(wstETH), address(rateFeed), address(usdFeed), RATE_MAX, USD_MAX);
  }

  function test_value_oneToken() public view {
    // 1 wstETH -> 1.2 stETH -> 1.2 * $4000 = 480_000 cents.
    assertEq(adapter.getValueInUSDCents(1e18), 480_000);
  }

  function test_value_isLinear() public view {
    assertEq(adapter.getValueInUSDCents(2e18), 960_000);
    assertEq(adapter.getValueInUSDCents(0), 0);
  }

  function test_reverts_whenRateFeedStale() public {
    uint256 staleAt = block.timestamp - (RATE_MAX + 1);
    rateFeed.setUpdatedAt(staleAt);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.StalePrice.selector, address(rateFeed), staleAt, RATE_MAX));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenUsdFeedStale() public {
    // rate feed stays fresh; only the USD feed is stale.
    uint256 staleAt = block.timestamp - (USD_MAX + 1);
    usdFeed.setUpdatedAt(staleAt);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.StalePrice.selector, address(usdFeed), staleAt, USD_MAX));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenRateNonPositive() public {
    rateFeed.setAnswer(0);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.NonPositivePrice.selector, address(rateFeed), int256(0)));
    adapter.getValueInUSDCents(1e18);
  }

  function test_ctor_reverts_onZeroAddress() public {
    vm.expectRevert(WstETHUSDL2PriceAdapter.ZeroAddress.selector);
    new WstETHUSDL2PriceAdapter(address(0), address(rateFeed), address(usdFeed), RATE_MAX, USD_MAX);
  }

  function test_ctor_reverts_onZeroRateStaleness() public {
    // rate staleness is validated first, so a zero rate reverts even with a valid usd.
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidMaxStaleness.selector, uint256(0), PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
      )
    );
    new WstETHUSDL2PriceAdapter(address(wstETH), address(rateFeed), address(usdFeed), 0, USD_MAX);
  }

  function test_ctor_reverts_onHugeUsdStaleness() public {
    // rate valid, usd out of band -> reverts for the usd value.
    uint256 tooBig = PriceFeedLib.STALENESS_MAX + 1;
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidMaxStaleness.selector, tooBig, PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
      )
    );
    new WstETHUSDL2PriceAdapter(address(wstETH), address(rateFeed), address(usdFeed), RATE_MAX, tooBig);
  }

  function test_ctor_acceptsBoundaryStaleness() public {
    // Inclusive bounds on both feeds are accepted.
    new WstETHUSDL2PriceAdapter(
      address(wstETH), address(rateFeed), address(usdFeed), PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
    );
  }
}
