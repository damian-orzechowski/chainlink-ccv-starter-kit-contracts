// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { WstETHUSDPriceAdapter } from "../src/oracle/WstETHUSDPriceAdapter.sol";
import { PriceFeedLib } from "../src/oracle/PriceFeedLib.sol";

import { MockAggregatorV3 } from "./mocks/MockAggregatorV3.sol";
import { MockWstETH } from "./mocks/MockWstETH.sol";

/// @notice Unit tests for the mainnet wstETH -> USD-cents adapter.
contract WstETHUSDPriceAdapterTest is Test {
  MockWstETH internal wstETH;
  MockAggregatorV3 internal feed; // stETH/USD, 8 decimals
  WstETHUSDPriceAdapter internal adapter;

  uint256 internal constant STETH_PER_WSTETH = 1.2e18; // 1 wstETH = 1.2 stETH
  int256 internal constant PRICE = 4000e8; // $4000 / stETH, 8 decimals
  uint256 internal constant MAX_STALENESS = 1 hours;
  uint256 internal constant START_TS = 1_000_000; // feed's updatedAt (set at setUp)

  function setUp() public {
    vm.warp(START_TS);
    wstETH = new MockWstETH(STETH_PER_WSTETH);
    feed = new MockAggregatorV3(8, PRICE, block.timestamp);
    adapter = new WstETHUSDPriceAdapter(address(wstETH), address(feed), MAX_STALENESS);
  }

  function test_value_oneToken() public view {
    // 1 wstETH -> 1.2 stETH -> 1.2 * $4000 = $4800 = 480_000 cents.
    assertEq(adapter.getValueInUSDCents(1e18), 480_000);
  }

  function test_value_isLinear() public view {
    assertEq(adapter.getValueInUSDCents(0.5e18), 240_000);
    assertEq(adapter.getValueInUSDCents(0), 0);
  }

  function test_value_handles18DecimalFeed() public {
    MockAggregatorV3 feed18 = new MockAggregatorV3(18, 4000e18, block.timestamp);
    WstETHUSDPriceAdapter a = new WstETHUSDPriceAdapter(address(wstETH), address(feed18), MAX_STALENESS);
    assertEq(a.getValueInUSDCents(1e18), 480_000);
  }

  function test_reverts_whenStale() public {
    vm.warp(block.timestamp + MAX_STALENESS + 1);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.StalePrice.selector, address(feed), START_TS, MAX_STALENESS));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenNonPositivePrice() public {
    feed.setAnswer(0);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.NonPositivePrice.selector, address(feed), int256(0)));
    adapter.getValueInUSDCents(1e18);
  }

  function test_ctor_reverts_onZeroAddress() public {
    vm.expectRevert(WstETHUSDPriceAdapter.ZeroAddress.selector);
    new WstETHUSDPriceAdapter(address(0), address(feed), MAX_STALENESS);
    vm.expectRevert(WstETHUSDPriceAdapter.ZeroAddress.selector);
    new WstETHUSDPriceAdapter(address(wstETH), address(0), MAX_STALENESS);
  }

  function test_metadata() public view {
    assertEq(adapter.token(), address(wstETH), "token()");
    assertEq(adapter.tokenDecimals(), 18, "tokenDecimals()");
  }

  function test_ctor_reverts_onWrongTokenDecimals() public {
    wstETH.setDecimals(6);
    vm.expectRevert(abi.encodeWithSelector(WstETHUSDPriceAdapter.UnexpectedTokenDecimals.selector, uint8(18), uint8(6)));
    new WstETHUSDPriceAdapter(address(wstETH), address(feed), MAX_STALENESS);
  }
}
