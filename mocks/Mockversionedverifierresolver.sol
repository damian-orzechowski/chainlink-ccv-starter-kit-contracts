// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VersionedVerifierResolver} from "@chainlink-ccip/ccvs/VersionedVerifierResolver.sol";

/// @notice Minimal resolver stand-in for the deploy-script test. Records what the
///         script registers, using the SAME upstream struct types so the call
///         selectors match what the script emits.
contract MockVersionedVerifierResolver {
  mapping(uint64 => address) public outbound; // destChainSelector -> verifier
  mapping(bytes4 => address) public inbound; // versionTag -> verifier

  function applyOutboundImplementationUpdates(VersionedVerifierResolver.OutboundImplementationArgs[] calldata args)
    external
  {
    for (uint256 i = 0; i < args.length; ++i) {
      outbound[args[i].destChainSelector] = args[i].verifier;
    }
  }

  function applyInboundImplementationUpdates(VersionedVerifierResolver.InboundImplementationArgs[] calldata args)
    external
  {
    for (uint256 i = 0; i < args.length; ++i) {
      inbound[args[i].version] = args[i].verifier;
    }
  }
}