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
  MockAggregatorV3 internal sequencer; // L2 sequencer uptime feed (answer 0=up)
  WstETHUSDL2PriceAdapter internal adapter;

  int256 internal constant RATE = 1.2e18; // 1.2 stETH per wstETH, 18 decimals
  int256 internal constant PRICE = 4000e8; // $4000 / stETH, 8 decimals
  uint256 internal constant RATE_MAX = 1 days;
  uint256 internal constant USD_MAX = 1 hours;
  uint256 internal constant GRACE = 1 hours;

  function setUp() public {
    vm.warp(1_000_000);
    wstETH = new MockWstETH(1e18);
    rateFeed = new MockAggregatorV3(18, RATE, block.timestamp);
    usdFeed = new MockAggregatorV3(8, PRICE, block.timestamp);
    sequencer = new MockAggregatorV3(0, 0, block.timestamp - (GRACE + 1));
    adapter = _deploy(RATE_MAX, USD_MAX, address(sequencer), GRACE);
  }

  /// @dev Deploy helper
  function _deploy(uint256 rateMax, uint256 usdMax, address seq, uint256 grace)
    internal
    returns (WstETHUSDL2PriceAdapter)
  {
    return new WstETHUSDL2PriceAdapter(
      address(wstETH), address(rateFeed), address(usdFeed), rateMax, usdMax, seq, grace
    );
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
    _deploy(RATE_MAX, USD_MAX, address(sequencer), GRACE);
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
    new WstETHUSDL2PriceAdapter(
      address(0), address(rateFeed), address(usdFeed), RATE_MAX, USD_MAX, address(sequencer), GRACE
    );
  }

  function test_ctor_reverts_onZeroSequencerFeed() public {
    // [Medium] audit finding #10: the sequencer uptime feed is required.
    vm.expectRevert(WstETHUSDL2PriceAdapter.ZeroAddress.selector);
    _deploy(RATE_MAX, USD_MAX, address(0), GRACE);
  }

  function test_ctor_reverts_onZeroRateStaleness() public {
    // rate staleness is validated first, so a zero rate reverts even with a valid usd.
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidMaxStaleness.selector, uint256(0), PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
      )
    );
    _deploy(0, USD_MAX, address(sequencer), GRACE);
  }

  function test_ctor_reverts_onHugeUsdStaleness() public {
    // rate valid, usd out of band -> reverts for the usd value.
    uint256 tooBig = PriceFeedLib.STALENESS_MAX + 1;
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidMaxStaleness.selector, tooBig, PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX
      )
    );
    _deploy(RATE_MAX, tooBig, address(sequencer), GRACE);
  }

  function test_ctor_acceptsBoundaryStaleness() public {
    // Inclusive bounds on both feeds are accepted.
    _deploy(PriceFeedLib.STALENESS_MIN, PriceFeedLib.STALENESS_MAX, address(sequencer), GRACE);
  }

  function test_ctor_reverts_onZeroGracePeriod() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidGracePeriod.selector,
        uint256(0),
        PriceFeedLib.GRACE_PERIOD_MIN,
        PriceFeedLib.GRACE_PERIOD_MAX
      )
    );
    _deploy(RATE_MAX, USD_MAX, address(sequencer), 0);
  }

  function test_ctor_reverts_onHugeGracePeriod() public {
    uint256 tooBig = PriceFeedLib.GRACE_PERIOD_MAX + 1;
    vm.expectRevert(
      abi.encodeWithSelector(
        PriceFeedLib.InvalidGracePeriod.selector, tooBig, PriceFeedLib.GRACE_PERIOD_MIN, PriceFeedLib.GRACE_PERIOD_MAX
      )
    );
    _deploy(RATE_MAX, USD_MAX, address(sequencer), tooBig);
  }

  function test_ctor_acceptsBoundaryGracePeriod() public {
    _deploy(RATE_MAX, USD_MAX, address(sequencer), PriceFeedLib.GRACE_PERIOD_MIN);
    _deploy(RATE_MAX, USD_MAX, address(sequencer), PriceFeedLib.GRACE_PERIOD_MAX);
  }

  function test_reverts_whenSequencerDown() public {
    sequencer.setAnswer(1); // 1 == down
    vm.expectRevert(PriceFeedLib.SequencerDown.selector);
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenSequencerRoundInvalid() public {
    // startedAt == 0 is an uninitialized/invalid round -> treated as down.
    sequencer.setUpdatedAt(0);
    vm.expectRevert(PriceFeedLib.SequencerDown.selector);
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_whenGracePeriodNotOver() public {
    // Sequencer just came up this block: timeSinceUp == 0 <= GRACE.
    sequencer.setUpdatedAt(block.timestamp);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.SequencerGracePeriodNotOver.selector, uint256(0), GRACE));
    adapter.getValueInUSDCents(1e18);
  }

  function test_reverts_atExactGraceBoundary() public {
    // timeSinceUp == GRACE is still within grace (the check is <=).
    sequencer.setUpdatedAt(block.timestamp - GRACE);
    vm.expectRevert(abi.encodeWithSelector(PriceFeedLib.SequencerGracePeriodNotOver.selector, GRACE, GRACE));
    adapter.getValueInUSDCents(1e18);
  }

  function test_pricesNormally_justPastGraceBoundary() public {
    // One second past the grace period, pricing proceeds as normal.
    sequencer.setUpdatedAt(block.timestamp - (GRACE + 1));
    assertEq(adapter.getValueInUSDCents(1e18), 480_000);
  }
}
