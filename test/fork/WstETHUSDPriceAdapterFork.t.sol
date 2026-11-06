// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { WstETHUSDPriceAdapter } from "../../src/price-adapters/WstETHUSDPriceAdapter.sol";

/// @notice Fork test for the mainnet wstETH adapter against live contracts/feeds.
///         Skips unless MAINNET_RPC_URL and WSTETH_USD_FEED (the Chainlink
///         wstETH/USD feed address) are set.
contract WstETHUSDPriceAdapterForkTest is Test {
  // Lido wstETH on Ethereum mainnet
  address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

  function test_fork_valueInSaneRange() public {
    string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
    address usdFeed = vm.envOr("WSTETH_USD_FEED", address(0));
    if (bytes(rpc).length == 0 || usdFeed == address(0)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);

    // Generous staleness so the pinned fork block doesn't trip the guard.
    WstETHUSDPriceAdapter adapter = new WstETHUSDPriceAdapter(WSTETH, usdFeed, 7 days);

    uint256 cents = adapter.getValueInUSDCents(1e18); // value of 1 wstETH
    // Very loose sanity band: $500 .. $100,000 (5e4 .. 1e7 cents).
    assertGe(cents, 50_000, "1 wstETH should be worth >= $500");
    assertLe(cents, 10_000_000, "1 wstETH should be worth <= $100k");
  }
}
