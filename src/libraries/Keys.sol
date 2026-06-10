// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The single authoritative derivation point for all deterministic keys in the protocol.
/// @dev Both PoolStorage and RiskEngine import this library, preventing mismatches from two independent implementations diverging.
library Keys {
    /// @notice Position key: unique for each (owner, collateral, debt) triple.
    function positionKey(address owner, address collateralAsset, address debtAsset) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, collateralAsset, debtAsset));
    }

    /// @notice Currency pair key: order-independent (normalized to min, max), so A↔B and B↔A resolve to the same entry.
    function pairKey(bytes32 currencyA, bytes32 currencyB) internal pure returns (bytes32) {
        return currencyA < currencyB
            ? keccak256(abi.encode(currencyA, currencyB))
            : keccak256(abi.encode(currencyB, currencyA));
    }
}
