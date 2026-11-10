// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {DeployVerifier} from "./DeployVerifier.s.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";

/// @title DeployBpsVerifier
/// @notice DeployVerifier for the BpsFeeCommitteeVerifier: same arguments, config, checks,
///         role handover and deployment record; only the implementation differs. The entry
///         is recorded with `"contract": "BpsFeeCommitteeVerifier"` so verify.sh picks the
///         right source.
///
/// @dev BpsFeeCommitteeVerifier IS a CommitteeVerifier, so every configure / ownership /
///      fee / governance script works on it unchanged by tag. Its own bps settings
///      (setFeeConfig, setPriceAdapter(s), setRequireAllTokensPriced) are owner calls made
///      after deploy; until then getFee falls back to the flat remoteChainConfig fee.
///      setFeeConfig needs the destination's remote chain config applied first.
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployBpsVerifier.s.sol --tc DeployBpsVerifier \
///     --sig "run(string,bytes4)" sepolia 0x00020001 --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployBpsVerifier is DeployVerifier {
  function _createVerifier(
    CommitteeVerifier.DynamicConfig memory dynamicConfig,
    string[] memory storageLocations,
    address rmn,
    bytes4 versionTag
  ) internal override returns (CommitteeVerifier) {
    return new BpsFeeCommitteeVerifier(dynamicConfig, storageLocations, rmn, versionTag);
  }

  function _contractName() internal pure override returns (string memory) {
    return "BpsFeeCommitteeVerifier";
  }
}
