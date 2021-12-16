// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.7;

import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

contract TestWhitelist {
  mapping(address => bool) public whitelist;

  function whitelistMe(
    uint8 kycType,
    uint8 countryOfIDIssuance,
    uint8 countryOfResidence,
    bytes32 rootHash,
    bytes calldata issuerSignature
  ) public {
    verify(
      kycType,
      countryOfIDIssuance,
      countryOfResidence,
      rootHash,
      issuerSignature
    );
    if (whitelist[msg.sender]) {
      revert('Already whitelisted');
    }
    whitelist[msg.sender] = true;
  }

  function verify(
    uint8 kycType,
    uint8 countryOfIDIssuance,
    uint8 countryOfResidence,
    bytes32 rootHash,
    bytes calldata issuerSignature
  ) internal view returns (bool) {
    bytes32 signable = computeKey(
      msg.sender, // could also be a function argument
      kycType,
      countryOfIDIssuance,
      countryOfResidence,
      rootHash
    );

    // FRACTAL_SIGNER is a hard-coded address for valid Fractal Signatures
    return
      verifyWithPrefix(
        signable,
        issuerSignature,
        0xa372CA5A906f7FAD480C49bBc73453672d4d375d
      );
  }

  function computeKey(
    address sender,
    uint8 kycType,
    uint8 countryOfIDIssuance,
    uint8 countryOfResidence,
    bytes32 rootHash
  ) public pure returns (bytes32) {
    return
      keccak256(
        abi.encodePacked(
          sender,
          kycType,
          countryOfResidence,
          countryOfIDIssuance,
          rootHash
        )
      );
  }

  function verifyWithPrefix(
    bytes32 hash,
    bytes calldata sig,
    address signer
  ) internal pure returns (bool) {
    return _verify(addPrefix(hash), sig, signer);
  }

  function addPrefix(bytes32 hash) private pure returns (bytes32) {
    bytes memory prefix = '\x19Ethereum Signed Message:\n32';

    return keccak256(abi.encodePacked(prefix, hash));
  }

  function _verify(
    bytes32 hash,
    bytes calldata sig,
    address signer
  ) internal pure returns (bool) {
    return ECDSA.recover(hash, sig) == signer;
  }
}
