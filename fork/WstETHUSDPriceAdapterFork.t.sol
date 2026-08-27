// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {WstETHUSDPriceAdapter} from "../../src/oracle/WstETHUSDPriceAdapter.sol";

/// @notice Fork test for the mainnet wstETH adapter against live contracts/feeds
///         Skips unless MAINNET_RPC_URL is set.
contract WstETHUSDPriceAdapterForkTest is Test {
  // Chainlink / Lido addresses
  address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant STETH_USD_FEED = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;

  function test_fork_valueInSaneRange() public {
    string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);

    // Generous staleness so the pinned fork block doesn't trip the guard.
    WstETHUSDPriceAdapter adapter = new WstETHUSDPriceAdapter(WSTETH, STETH_USD_FEED, 7 days);

    uint256 cents = adapter.getValueInUSDCents(1e18); // value of 1 wstETH
    // Very loose sanity band: $500 .. $100,000 (5e4 .. 1e7 cents).
    assertGe(cents, 50_000, "1 wstETH should be worth >= $500");
    assertLe(cents, 10_000_000, "1 wstETH should be worth <= $100k");
  }
}
