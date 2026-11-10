// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployPriceAdapter} from "../../script/deploy/DeployPriceAdapter.s.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {WstETHUSDL2PriceAdapter} from "../../src/price-adapters/WstETHUSDL2PriceAdapter.sol";
import {WstETHUSDPriceAdapter} from "../../src/price-adapters/WstETHUSDPriceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockWstETH} from "../mocks/MockWstETH.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The declared `priceAdapters[]` operator entries, their deployment record, and
///         the deploy script that turns one into the other.
/// @dev Forge runs tests concurrently against one filesystem, so every fixture is its own
///      path under out/governance/; the trailing removeFile is courtesy only.
contract DeployPriceAdapterTest is Test {
  string internal constant DIR = "out/governance/";
  address internal constant TOKEN = address(0x7000000000000000000000000000000000000001);
  address internal constant OTHER_TOKEN = address(0x7000000000000000000000000000000000000002);
  address internal constant FEED_A = address(0x7000000000000000000000000000000000000003);
  address internal constant FEED_B = address(0x7000000000000000000000000000000000000004);
  address internal constant SEQUENCER = address(0x7000000000000000000000000000000000000005);

  Reader internal reader;
  Harness internal harness;

  function setUp() public {
    vm.createDir("out/governance", true);
    vm.warp(30 days);
    reader = new Reader();
    harness = new Harness();
  }

  // ===========================================================================
  //  operator config: priceAdapters[]
  // ===========================================================================

  function test_readOperator_parsesBothAdapterKinds() public {
    Types.OperatorConfig memory op = _readOperator("both", string.concat(_l1Entry(TOKEN), ",", _l2Entry(OTHER_TOKEN)));

    assertEq(op.priceAdapters.length, 2);
    Types.PriceAdapterConfig memory l1 = ConfigLib.priceAdapterConfigByToken(op, TOKEN);
    assertEq(l1.contractName, "WstETHUSDPriceAdapter");
    assertEq(l1.usdFeed, FEED_A);
    assertEq(l1.usdMaxStaleness, 90_000);
    assertEq(l1.rateFeed, address(0), "L2-only fields stay zero on an L1 adapter");

    Types.PriceAdapterConfig memory l2 = ConfigLib.priceAdapterConfigByToken(op, OTHER_TOKEN);
    assertEq(l2.contractName, "WstETHUSDL2PriceAdapter");
    assertEq(l2.rateFeed, FEED_A);
    assertEq(l2.usdFeed, FEED_B);
    assertEq(l2.rateMaxStaleness, 86_400);
    assertEq(l2.usdMaxStaleness, 3600);
    assertEq(l2.sequencerUptimeFeed, SEQUENCER);
    assertEq(l2.gracePeriod, 3600);
  }

  /// @dev Every pre-existing operator file has no priceAdapters key.
  function test_readOperator_absentArrayReadsEmpty() public view {
    Types.OperatorConfig memory op = ConfigLib.readOperatorByPath("config/operator/chains/sepolia.example.json");
    assertEq(op.priceAdapters.length, 0);
  }

  function test_readOperator_rejectsAnL2KeyOnAnL1Adapter() public {
    _expectOperatorRevert(
      "l2-key-on-l1",
      string.concat(
        '{"contract":"WstETHUSDPriceAdapter","token":"',
        vm.toString(TOKEN),
        '","usdFeed":"',
        vm.toString(FEED_A),
        '","usdMaxStaleness":90000,"gracePeriod":3600}'
      ),
      "unknown key 'gracePeriod'"
    );
  }

  function test_readOperator_rejectsAMissingKey() public {
    _expectOperatorRevert(
      "missing-key",
      string.concat('{"contract":"WstETHUSDPriceAdapter","token":"', vm.toString(TOKEN), '","usdMaxStaleness":90000}'),
      "missing .priceAdapters[0].usdFeed"
    );
  }

  function test_readOperator_rejectsAZeroFeed() public {
    _expectOperatorRevert(
      "zero-feed",
      string.concat(
        '{"contract":"WstETHUSDPriceAdapter","token":"',
        vm.toString(TOKEN),
        '","usdFeed":"0x0000000000000000000000000000000000000000","usdMaxStaleness":90000}'
      ),
      "zero address at .priceAdapters[0].usdFeed"
    );
  }

  function test_readOperator_rejectsAnUnknownContract() public {
    _expectOperatorRevert(
      "unknown-contract", '{"contract":"SomethingElse"}', "must be WstETHUSDPriceAdapter or WstETHUSDL2PriceAdapter"
    );
  }

  function test_readOperator_rejectsADuplicateToken() public {
    _expectOperatorRevert(
      "dup-token", string.concat(_l1Entry(TOKEN), ",", _l2Entry(TOKEN)), "duplicate priceAdapters token"
    );
  }

  function test_priceAdapterConfigByToken_revertsWhenUndeclared() public {
    Types.OperatorConfig memory op = _readOperator("undeclared", _l1Entry(TOKEN));
    vm.expectRevert();
    reader.configByToken(op, OTHER_TOKEN);
  }

  // ===========================================================================
  //  deployment record: priceAdapters[]
  // ===========================================================================

  function test_record_roundTripsPriceAdapters() public {
    string memory path = string.concat(DIR, "adapter-record.local.json");
    Types.Deployment memory d;
    d.aliasName = "testchain";
    d.priceAdapters = new Types.PriceAdapterDeployment[](2);
    d.priceAdapters[0] = _l1Record(address(0xA1));
    d.priceAdapters[1] = _l2Record(address(0xA2));
    ConfigLib.writeDeploymentByPath(path, d);

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.priceAdapters.length, 2);
    assertEq(got.priceAdapters[0].addr, address(0xA1));
    assertEq(got.priceAdapters[0].args.contractName, "WstETHUSDPriceAdapter");
    assertEq(got.priceAdapters[0].args.usdMaxStaleness, 90_000);
    assertEq(got.priceAdapters[0].encodedArgs, d.priceAdapters[0].encodedArgs);
    assertEq(got.priceAdapters[1].args.contractName, "WstETHUSDL2PriceAdapter");
    assertEq(got.priceAdapters[1].args.sequencerUptimeFeed, SEQUENCER);
    assertEq(got.priceAdapters[1].args.gracePeriod, 3600);
    assertEq(got.priceAdapters[1].encodedArgs, d.priceAdapters[1].encodedArgs);
    assertEq(ConfigLib.priceAdapterByToken(got, OTHER_TOKEN), address(0xA2));

    vm.removeFile(path);
  }

  /// @dev Every deploy script rewrites the whole record: a verifier deploy after an
  ///      adapter deploy must carry the adapters through untouched.
  function test_record_verifierRewriteKeepsAdapters() public {
    string memory path = string.concat(DIR, "adapter-record-rewrite.local.json");
    Types.Deployment memory d;
    d.aliasName = "testchain";
    d.priceAdapters = new Types.PriceAdapterDeployment[](1);
    d.priceAdapters[0] = _l1Record(address(0xA1));
    ConfigLib.writeDeploymentByPath(path, d);

    Types.Deployment memory reread = ConfigLib.readDeploymentByPath(path);
    reread.resolver = address(0xBEEF);
    ConfigLib.writeDeploymentByPath(path, reread);

    assertEq(ConfigLib.readDeploymentByPath(path).priceAdapters[0].addr, address(0xA1));
    vm.removeFile(path);
  }

  function test_record_templateReadsEmpty() public view {
    assertEq(ConfigLib.readDeploymentByPath("config/deployments/_template.json").priceAdapters.length, 0);
  }

  /// @dev Records written before the key existed hold no adapters.
  function test_record_absentArrayReadsEmpty() public {
    string memory path = string.concat(DIR, "adapter-record-legacy.local.json");
    vm.writeFile(
      path,
      '{"alias":"raw","factory":{"address":"0x0000000000000000000000000000000000000000"},'
      '"resolver":{"address":"0x0000000000000000000000000000000000000000"},"verifiers":[]}'
    );
    assertEq(ConfigLib.readDeploymentByPath(path).priceAdapters.length, 0);
    vm.removeFile(path);
  }

  // ===========================================================================
  //  DeployPriceAdapter
  // ===========================================================================

  function test_createAdapter_l1MatchesTheDeclaredArgs() public {
    MockWstETH token = new MockWstETH();
    MockAggregatorV3 usdFeed = new MockAggregatorV3(8, 4000e8, block.timestamp);
    Types.PriceAdapterConfig memory c;
    c.contractName = "WstETHUSDPriceAdapter";
    c.token = address(token);
    c.usdFeed = address(usdFeed);
    c.usdMaxStaleness = 90_000;

    Types.PriceAdapterDeployment memory r = harness.create(c);

    WstETHUSDPriceAdapter adapter = WstETHUSDPriceAdapter(r.addr);
    assertEq(adapter.token(), address(token));
    assertEq(address(adapter.USD_FEED()), address(usdFeed));
    assertEq(adapter.MAX_STALENESS(), 90_000);
    assertEq(adapter.getValueInUSDCents(1e18), 400_000, "1 wstETH at $4000");
    assertEq(r.encodedArgs, abi.encode(address(token), address(usdFeed), uint256(90_000)));
  }

  function test_createAdapter_l2MatchesTheDeclaredArgs() public {
    MockWstETH token = new MockWstETH();
    Types.PriceAdapterConfig memory c;
    c.contractName = "WstETHUSDL2PriceAdapter";
    c.token = address(token);
    c.rateFeed = address(new MockAggregatorV3(18, 1.2e18, block.timestamp));
    c.usdFeed = address(new MockAggregatorV3(8, 4000e8, block.timestamp));
    c.rateMaxStaleness = 86_400;
    c.usdMaxStaleness = 3600;
    c.sequencerUptimeFeed = address(new MockAggregatorV3(0, 0, block.timestamp - 2 hours));
    c.gracePeriod = 3600;

    Types.PriceAdapterDeployment memory r = harness.create(c);

    WstETHUSDL2PriceAdapter adapter = WstETHUSDL2PriceAdapter(r.addr);
    assertEq(adapter.token(), address(token));
    assertEq(address(adapter.RATE_FEED()), c.rateFeed);
    assertEq(address(adapter.SEQUENCER_UPTIME_FEED()), c.sequencerUptimeFeed);
    assertEq(adapter.GRACE_PERIOD(), 3600);
    assertEq(adapter.getValueInUSDCents(1e18), 480_000, "1.2 ETH at $4000");
    assertEq(
      r.encodedArgs,
      abi.encode(
        c.token, c.rateFeed, c.usdFeed, c.rateMaxStaleness, c.usdMaxStaleness, c.sequencerUptimeFeed, c.gracePeriod
      )
    );
  }

  function test_recordAdapter_appendsPerToken() public view {
    Types.Deployment memory d;
    d.aliasName = "local";
    d = harness.record(d, _l1Record(address(0xA1)), false);
    d = harness.record(d, _l2Record(address(0xA2)), false);
    assertEq(d.priceAdapters.length, 2);
  }

  function test_recordAdapter_duplicateTokenRevertsWithoutWaiver() public {
    Types.Deployment memory d;
    d.aliasName = "local";
    d = harness.record(d, _l1Record(address(0xA1)), false);

    vm.expectRevert(
      bytes(
        string.concat(
          "DeployPriceAdapter: a price adapter for token ",
          vm.toString(TOKEN),
          " is already recorded for local - set ALLOW_ADAPTER_REPLACE=true to replace it"
        )
      )
    );
    harness.record(d, _l1Record(address(0xB1)), false);
  }

  function test_recordAdapter_waiverReplacesInPlace() public view {
    Types.Deployment memory d;
    d.aliasName = "local";
    d = harness.record(d, _l1Record(address(0xA1)), false);
    d = harness.record(d, _l1Record(address(0xB1)), true);

    assertEq(d.priceAdapters.length, 1, "replaced, not appended");
    assertEq(d.priceAdapters[0].addr, address(0xB1));
  }

  // ===========================================================================
  //  fixtures
  // ===========================================================================

  function _l1Entry(
    address token
  ) internal pure returns (string memory) {
    return string.concat(
      '{"contract":"WstETHUSDPriceAdapter","token":"',
      vm.toString(token),
      '","usdFeed":"',
      vm.toString(FEED_A),
      '","usdMaxStaleness":90000}'
    );
  }

  function _l2Entry(
    address token
  ) internal pure returns (string memory) {
    return string.concat(
      '{"contract":"WstETHUSDL2PriceAdapter","token":"',
      vm.toString(token),
      '","rateFeed":"',
      vm.toString(FEED_A),
      '","rateMaxStaleness":86400,"usdFeed":"',
      vm.toString(FEED_B),
      '","usdMaxStaleness":3600,"sequencerUptimeFeed":"',
      vm.toString(SEQUENCER),
      '","gracePeriod":3600}'
    );
  }

  function _l1Record(
    address addr
  ) internal pure returns (Types.PriceAdapterDeployment memory r) {
    r.addr = addr;
    r.args.contractName = "WstETHUSDPriceAdapter";
    r.args.token = TOKEN;
    r.args.usdFeed = FEED_A;
    r.args.usdMaxStaleness = 90_000;
    r.encodedArgs = abi.encode(TOKEN, FEED_A, uint256(90_000));
  }

  function _l2Record(
    address addr
  ) internal pure returns (Types.PriceAdapterDeployment memory r) {
    r.addr = addr;
    r.args.contractName = "WstETHUSDL2PriceAdapter";
    r.args.token = OTHER_TOKEN;
    r.args.rateFeed = FEED_A;
    r.args.usdFeed = FEED_B;
    r.args.rateMaxStaleness = 86_400;
    r.args.usdMaxStaleness = 3600;
    r.args.sequencerUptimeFeed = SEQUENCER;
    r.args.gracePeriod = 3600;
    r.encodedArgs = abi.encode(OTHER_TOKEN, FEED_A, FEED_B, uint256(86_400), uint256(3600), SEQUENCER, uint256(3600));
  }

  function _operatorJson(
    string memory adapters
  ) internal pure returns (string memory) {
    return string.concat(
      '{"alias":"tmp-adapters","verifiers":[],',
      '"resolver":{"roles":{"owner":"0x2000000000000000000000000000000000000001",',
      '"feeAggregator":"0x2000000000000000000000000000000000000005"}},',
      '"factory":{"roles":{"owner":"0x2000000000000000000000000000000000000001","allowlist":[]}},',
      '"priceAdapters":[',
      adapters,
      "]}"
    );
  }

  function _readOperator(
    string memory caseName,
    string memory adapters
  ) internal returns (Types.OperatorConfig memory op) {
    string memory path = string.concat(DIR, "adapters-", caseName, ".local.json");
    vm.writeFile(path, _operatorJson(adapters));
    op = ConfigLib.readOperatorByPath(path);
    vm.removeFile(path);
  }

  function _expectOperatorRevert(
    string memory caseName,
    string memory adapters,
    string memory reasonFragment
  ) internal {
    string memory path = string.concat(DIR, "adapters-", caseName, ".local.json");
    vm.writeFile(path, _operatorJson(adapters));
    try reader.readOperator(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), reason);
    }
    vm.removeFile(path);
  }
}

/// @dev External seams so reverts are observable from the test.
contract Reader {
  function readOperator(
    string memory path
  ) external view returns (Types.OperatorConfig memory) {
    return ConfigLib.readOperatorByPath(path);
  }

  function configByToken(
    Types.OperatorConfig memory op,
    address token
  ) external pure returns (Types.PriceAdapterConfig memory) {
    return ConfigLib.priceAdapterConfigByToken(op, token);
  }
}

contract Harness is DeployPriceAdapter {
  function create(
    Types.PriceAdapterConfig memory c
  ) external returns (Types.PriceAdapterDeployment memory) {
    return _createAdapter(c);
  }

  function record(
    Types.Deployment memory deployment,
    Types.PriceAdapterDeployment memory entry,
    bool allowReplace
  ) external pure returns (Types.Deployment memory) {
    _recordAdapter(deployment, entry, allowReplace);
    return deployment;
  }
}
