// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { DeployCustomFeeCommitteeVerifier } from "../script/DeployCustomFeeCommitteeVerifier.s.sol";
import { CustomFeeCommitteeVerifier } from "../src/CustomFeeCommitteeVerifier.sol";
import { CustomFeeConfig } from "../src/config/CustomFeeConfig.sol";
import { IPriceAdapter } from "../src/oracle/IPriceAdapter.sol";

import { Client } from "@chainlink-ccip/libraries/Client.sol";

import { MockPriceAdapter } from "./mocks/MockPriceAdapter.sol";
import { MockVersionedVerifierResolver } from "./mocks/MockVersionedVerifierResolver.sol";

/// @dev Exposes the script's internal load/deploy so tests can drive them with
///      an in-memory Config (no file, env, or broadcast required).
contract DeployHarness is DeployCustomFeeCommitteeVerifier {
  function loadFrom(string memory path) external view returns (Config memory) {
    return _load(path);
  }

  function deployFor(Config memory cfg) external returns (CustomFeeCommitteeVerifier) {
    return _deploy(cfg);
  }
}

contract DeployScriptTest is Test {
  DeployHarness internal harness;

  // Wiring-test constants.
  uint64 internal constant DEST = 111;
  uint64 internal constant SRC = 222;
  bytes4 internal constant VERSION_TAG = bytes4(uint32(7));

  function setUp() public {
    harness = new DeployHarness();
  }

  // --- JSON parsing (validates the alphabetical struct decode) ---------------

  function test_load_parsesExampleConfig() public view {
    DeployCustomFeeCommitteeVerifier.Config memory cfg = harness.loadFrom("script/config/deploy.example.json");

    assertEq(cfg.rmn, 0x0000000000000000000000000000000000000001, "rmn");
    assertEq(cfg.versionTag, bytes4(uint32(1)), "versionTag");

    assertEq(cfg.chains.length, 1, "chains len");
    assertEq(cfg.chains[0].chainSelector, 4949039107694359620, "chainSelector");
    assertEq(cfg.chains[0].feeBps, 5, "feeBps");
    assertEq(cfg.chains[0].capUSDCents, 1000, "capUSDCents");
    assertEq(cfg.chains[0].minFeeUSDCents, 10, "minFeeUSDCents");
    assertEq(cfg.chains[0].gasForVerification, 90_000, "gasForVerification");
    assertEq(cfg.chains[0].payloadSizeBytes, 256, "payloadSizeBytes");
    assertTrue(cfg.chains[0].enabled, "enabled");

    assertEq(cfg.adapters.length, 1, "adapters len");
    assertEq(cfg.adapters[0].token, 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "adapter token");

    assertEq(cfg.sigs.length, 1, "sigs len");
    assertEq(cfg.sigs[0].sourceChainSelector, 5009297550715157269, "sourceChainSelector");
    assertEq(cfg.sigs[0].threshold, 2, "threshold");
    assertEq(cfg.sigs[0].signers.length, 3, "signers len");
  }

  // --- end-to-end wiring (deploy + configure + register) ---------------------

  function test_deploy_wiresVerifierConfigAndResolver() public {
    address token = makeAddr("wstETHToken");
    MockPriceAdapter adapter = new MockPriceAdapter(100_000); // $1000 / token
    MockVersionedVerifierResolver resolver = new MockVersionedVerifierResolver();

    CustomFeeCommitteeVerifier verifier = harness.deployFor(_buildConfig(token, address(adapter), address(resolver)));

    _assertConfigured(verifier, token, address(adapter));
    _assertGetFee(verifier, token);
    _assertResolver(resolver, address(verifier));
  }

  // --- helpers (each in its own frame to bound stack depth) ------------------

  function _buildConfig(address token, address adapter, address resolver)
    internal
    returns (DeployCustomFeeCommitteeVerifier.Config memory cfg)
  {
    cfg.rmn = makeAddr("rmn");
    cfg.feeAggregator = makeAddr("agg");
    cfg.allowlistAdmin = makeAddr("allowlistAdmin");
    cfg.versionTag = VERSION_TAG;
    cfg.storageLocations = new string[](0);
    cfg.resolver = resolver;

    cfg.chains = new DeployCustomFeeCommitteeVerifier.RemoteChainInput[](1);
    cfg.chains[0] = DeployCustomFeeCommitteeVerifier.RemoteChainInput({
      capUSDCents: 1000,
      chainSelector: DEST,
      enabled: true,
      feeBps: 5,
      flatFeeUSDCents: 25,
      gasForVerification: 90_000,
      minFeeUSDCents: 10,
      payloadSizeBytes: 256,
      router: address(0)
    });

    cfg.adapters = new DeployCustomFeeCommitteeVerifier.PriceAdapterInput[](1);
    cfg.adapters[0] = DeployCustomFeeCommitteeVerifier.PriceAdapterInput({ adapter: adapter, token: token });

    address[] memory signers = new address[](2);
    signers[0] = makeAddr("signer1");
    signers[1] = makeAddr("signer2");
    // Some quorum validators require a strictly-ascending signer set; order them.
    if (uint160(signers[0]) > uint160(signers[1])) {
      (signers[0], signers[1]) = (signers[1], signers[0]);
    }
    cfg.sigs = new DeployCustomFeeCommitteeVerifier.SignatureConfigInput[](1);
    cfg.sigs[0] = DeployCustomFeeCommitteeVerifier.SignatureConfigInput({
      signers: signers, sourceChainSelector: SRC, threshold: 2
    });
  }

  function _assertConfigured(CustomFeeCommitteeVerifier verifier, address token, address adapter) internal view {
    assertTrue(address(verifier) != address(0), "deployed");
    assertEq(verifier.owner(), address(harness), "owner");

    CustomFeeConfig memory fc = verifier.getFeeConfig(DEST);
    assertEq(fc.feeBps, 5, "feeBps");
    assertTrue(fc.enabled, "enabled");
    assertEq(fc.capUSDCents, 1000, "cap");
    assertEq(address(verifier.getPriceAdapter(token)), adapter, "adapter registered");
  }

  function _assertGetFee(CustomFeeCommitteeVerifier verifier, address token) internal view {
    // 1 token == $1000 == 100_000 cents; * 5 / 10_000 = 50; base gas/payload passthrough.
    Client.EVM2AnyMessage memory m;
    m.tokenAmounts = new Client.EVMTokenAmount[](1);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: token, amount: 1e18 });
    (uint16 fee, uint32 gas, uint32 payload) = verifier.getFee(DEST, m, "", bytes4(0));
    assertEq(fee, 50, "fee");
    assertEq(gas, 90_000, "gas");
    assertEq(payload, 256, "payload");
  }

  function _assertResolver(MockVersionedVerifierResolver resolver, address verifier) internal view {
    assertEq(resolver.outbound(DEST), verifier, "outbound");
    assertEq(resolver.inbound(VERSION_TAG), verifier, "inbound");
  }
}
