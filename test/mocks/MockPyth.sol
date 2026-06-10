// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice Test Pyth contract with a settable price per feed id (simulates de-peg / staleness / exponents).
contract MockPyth is IPyth {
    mapping(bytes32 id => Price) internal prices;

    /// @notice Set the full Price tuple for a feed id.
    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime)
        external
    {
        prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    /// @notice Convenience: set a price with expo -8 and publishTime = now.
    function setPriceE8(bytes32 id, int64 price) external {
        prices[id] = Price({price: price, conf: 0, expo: -8, publishTime: block.timestamp});
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return prices[id];
    }

    function getPriceNoOlderThan(bytes32 id, uint256) external view override returns (Price memory) {
        return prices[id];
    }

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {}
}
