// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BasePriceOracle} from "../../src/oracles/BasePriceOracle.sol";
import {FeedNotSet, InvalidPrice} from "../../src/libraries/DataTypes.sol";

/// @notice Test price source: a plain settable 1e8-USD price container, decoupled from any real
///         oracle vendor. Reuses BasePriceOracle's guardian/pause logic so pause-related tests
///         behave identically to production oracles.
/// @dev Prices are stored already normalized to the 1e8 USD base — there is no decimals/staleness
///      simulation here (that is each concrete oracle's own concern; see ChainlinkPriceOracle).
contract MockPriceOracle is BasePriceOracle {
    /// @notice Asset => 1e8-base USD price (0 = unset).
    mapping(address asset => uint256) public price;

    constructor(address initialOwner) BasePriceOracle(initialOwner) {}

    /// @notice Set the 1e8-base USD price for an asset.
    function setPrice(address asset, uint256 price_) external {
        price[asset] = price_;
    }

    /// @inheritdoc BasePriceOracle
    function _readPrice(address asset) internal view override returns (uint256) {
        uint256 p = price[asset];
        if (p == 0) revert FeedNotSet(asset);
        return p;
    }
}
