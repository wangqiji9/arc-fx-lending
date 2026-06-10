// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPyth} from "../interfaces/IPyth.sol";
import {BasePriceOracle} from "./BasePriceOracle.sol";
import {StalePrice, InvalidPrice, FeedNotSet, ZeroAddress} from "../libraries/DataTypes.sol";

/// @title PythPriceOracle
/// @notice Pyth-based price source for Arc. Extends BasePriceOracle for shared guardian/pause logic.
/// @dev Pyth is a PULL oracle: the on-chain price is only as fresh as the last updatePriceFeeds call,
///      so a keeper (or transaction-embedded updates) must keep it current; this contract reads the
///      stored price and enforces a per-asset maxAge, surfacing the protocol's StalePrice error —
///      same error surface as ChainlinkPriceOracle so consumers/tests treat both oracles identically.
///      Prices are normalized to the 1e8 USD base (architecture.md §8). USD crypto feeds carry expo=-8,
///      which already equals 1e8 base (passthrough); other exponents are shifted accordingly.
contract PythPriceOracle is BasePriceOracle {
    struct FeedConfig {
        bytes32 priceId; // Pyth price feed id (bytes32, chain-agnostic)
        uint32 maxAge; // maximum acceptable staleness in seconds (analogous to Chainlink heartbeat)
        bool set; // whether the feed has been configured
    }

    /// @notice The Pyth contract on this chain (Arc testnet: 0x2880aB155794e7179c9eE2e38200202908C17B43).
    IPyth public immutable pyth;

    /// @notice Asset => Pyth feed configuration.
    mapping(address asset => FeedConfig) public feeds;

    event FeedSet(address indexed asset, bytes32 priceId, uint32 maxAge);

    constructor(address initialOwner, address pyth_) BasePriceOracle(initialOwner) {
        if (pyth_ == address(0)) revert ZeroAddress();
        pyth = IPyth(pyth_);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure the Pyth price id + max staleness for an asset.
    function setFeed(address asset, bytes32 priceId, uint32 maxAge) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (priceId == bytes32(0) || maxAge == 0) revert InvalidPrice(asset);
        feeds[asset] = FeedConfig({priceId: priceId, maxAge: maxAge, set: true});
        emit FeedSet(asset, priceId, maxAge);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL READ
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc BasePriceOracle
    function _readPrice(address asset) internal view override returns (uint256) {
        FeedConfig memory cfg = feeds[asset];
        if (!cfg.set) revert FeedNotSet(asset);

        IPyth.Price memory p = pyth.getPriceUnsafe(cfg.priceId);

        // Sanity: price must be positive
        if (p.price <= 0) revert InvalidPrice(asset);

        // Staleness: reject if the stored price is older than maxAge.
        // Guard against publishTime slightly ahead of block.timestamp (Pyth can publish near-future ts).
        uint256 age = block.timestamp > p.publishTime ? block.timestamp - p.publishTime : 0;
        if (age > cfg.maxAge) revert StalePrice(address(pyth));

        // p.price guaranteed > 0 here, so the cast is safe
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(uint64(p.price));

        // Normalize to 1e8 USD base: target = price * 10^(expo + 8).
        int256 shift = int256(p.expo) + 8;
        if (shift == 0) {
            return price; // expo == -8 (typical USD crypto feed) → already 1e8 base
        } else if (shift > 0) {
            return price * (10 ** uint256(shift));
        } else {
            // shift < 0 here, so -shift is always positive → cast is safe
            // forge-lint: disable-next-line(unsafe-typecast)
            return price / (10 ** uint256(-shift));
        }
    }
}
