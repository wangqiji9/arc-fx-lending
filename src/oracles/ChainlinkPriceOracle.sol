// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {BasePriceOracle} from "./BasePriceOracle.sol";
import {StalePrice, InvalidPrice, FeedNotSet, ZeroAddress} from "../libraries/DataTypes.sol";

/// @title ChainlinkPriceOracle
/// @notice Chainlink AggregatorV3–based price source with staleness + sanity checks.
///         Extends BasePriceOracle for shared guardian/pause logic.
/// @dev All prices are normalized to a 1e8 USD base. Even stablecoins go through a live feed
///      (not hardcoded to 1) so that depegging is observable (architecture.md §7).
contract ChainlinkPriceOracle is BasePriceOracle {
    struct FeedConfig {
        address feed; // Chainlink aggregator
        uint32 heartbeat; // Maximum acceptable staleness in seconds
        uint8 feedDecimals; // Feed quote decimals (cached to save one external call)
        bool set; // Whether the feed has been configured
    }

    /// @notice Asset => Chainlink feed configuration.
    mapping(address asset => FeedConfig) public feeds;

    event FeedSet(address indexed asset, address feed, uint32 heartbeat, uint8 feedDecimals);

    constructor(address initialOwner) BasePriceOracle(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure the Chainlink feed + heartbeat for an asset. Feed decimals are read and cached on-chain.
    function setFeed(address asset, address feed, uint32 heartbeat) external onlyOwner {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        if (heartbeat == 0) revert InvalidPrice(asset);
        uint8 dec = IAggregatorV3(feed).decimals();
        feeds[asset] = FeedConfig({feed: feed, heartbeat: heartbeat, feedDecimals: dec, set: true});
        emit FeedSet(asset, feed, heartbeat, dec);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL READ
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc BasePriceOracle
    function _readPrice(address asset) internal view override returns (uint256) {
        FeedConfig memory cfg = feeds[asset];
        if (!cfg.set) revert FeedNotSet(asset);

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(cfg.feed).latestRoundData();

        // Sanity: price must be positive
        if (answer <= 0) revert InvalidPrice(asset);
        // Staleness: reject if price exceeds heartbeat age
        if (block.timestamp - updatedAt > cfg.heartbeat) revert StalePrice(cfg.feed);

        // answer is guaranteed > 0 here, so casting to uint256 is always safe
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);

        // Normalize to 1e8 USD base
        if (cfg.feedDecimals == 8) {
            return price;
        } else if (cfg.feedDecimals < 8) {
            return price * (10 ** (8 - cfg.feedDecimals));
        } else {
            return price / (10 ** (cfg.feedDecimals - 8));
        }
    }
}
