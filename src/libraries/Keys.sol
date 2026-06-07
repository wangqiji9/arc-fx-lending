// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice 协议内所有确定性 key 的【唯一】派生处。
/// @dev PoolStorage 与 RiskEngine 都引用本库,杜绝两份实现走歪导致 key 对不上。
library Keys {
    /// @notice 仓位 key:每个 (owner, 抵押, 债务) 三元组唯一。
    function positionKey(address owner, address collateralAsset, address debtAsset)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, collateralAsset, debtAsset));
    }

    /// @notice 货币对 key:与顺序无关(min,max 归一),A↔B 与 B↔A 命中同一条。
    function pairKey(bytes32 currencyA, bytes32 currencyB) internal pure returns (bytes32) {
        return currencyA < currencyB
            ? keccak256(abi.encode(currencyA, currencyB))
            : keccak256(abi.encode(currencyB, currencyA));
    }
}
