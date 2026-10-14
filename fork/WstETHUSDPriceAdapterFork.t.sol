// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { WstETHUSDPriceAdapter } from "../../src/oracle/WstETHUSDPriceAdapter.sol";

/// @notice Fork test for the mainnet wstETH adapter against live contracts/feeds.
///         Skips unless MAINNET_RPC_URL and WSTETH_ETH_FEED are set. The
///         wstETH/ETH feed address is supplied by the operator; ETH/USD is
///         Chainlink's canonical mainnet aggregator.
contract WstETHUSDPriceAdapterForkTest is Test {
  // Lido wstETH / Chainlink ETH/USD on Ethereum mainnet
  address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  function test_fork_valueInSaneRange() public {
    string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
    address rateFeed = vm.envOr("WSTETH_ETH_FEED", address(0));
    if (bytes(rpc).length == 0 || rateFeed == address(0)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);

    // Generous staleness so the pinned fork block doesn't trip the guard.
    WstETHUSDPriceAdapter adapter = new WstETHUSDPriceAdapter(WSTETH, rateFeed, ETH_USD_FEED, 7 days, 7 days);

    uint256 cents = adapter.getValueInUSDCents(1e18); // value of 1 wstETH
    // Very loose sanity band: $500 .. $100,000 (5e4 .. 1e7 cents).
    assertGe(cents, 50_000, "1 wstETH should be worth >= $500");
    assertLe(cents, 10_000_000, "1 wstETH should be worth <= $100k");
  }
}
