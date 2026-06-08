// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {StalePrice, InvalidPrice, FeedNotSet, NotAuthorized, ZeroAddress} from "./libraries/DataTypes.sol";

/// @title PriceOracle
/// @notice Chainlink price aggregation + Layer 2 circuit breaker (architecture.md §4.6 / §7).
///         Option B: on-chain logic is limited to staleness + sanity checks (pure view);
///         deviation (depeg) monitoring is done off-chain — the guardian calls setPaused upon
///         detecting an anomaly. Pausing only blocks new borrows/deposits; repay/liquidate are unaffected.
/// @dev All prices are normalized to a 1e8 USD base. Even USDC goes through a feed (not hardcoded to 1),
///      because hardcoding prevents observation of USDC depegging — and depegging is the core tail risk in §7.
contract PriceOracle is IPriceOracle, Ownable {
    struct FeedConfig {
        address feed; // Chainlink aggregator
        uint32 heartbeat; // Maximum acceptable staleness in seconds (beyond this = stale)
        uint8 feedDecimals; // Feed quote decimals (cached to save one external call)
        bool set; // Whether the feed has been configured
    }

    /// @notice Asset => feed configuration.
    mapping(address asset => FeedConfig) public feeds;

    /// @notice Asset => whether circuit-breaker pause is active.
    mapping(address asset => bool) public paused;

    /// @notice Hot wallet that can trigger a pause (separate from admin for fast response to depeg events).
    address public guardian;

    event FeedSet(address indexed asset, address feed, uint32 heartbeat, uint8 feedDecimals);
    event GuardianSet(address indexed guardian);
    event PausedSet(address indexed asset, bool paused);

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                              ADMIN / GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure the Chainlink feed + heartbeat for an asset. Feed decimals are read and cached on-chain.
    function setFeed(address asset, address feed, uint32 heartbeat) external onlyOwner {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        if (heartbeat == 0) revert InvalidPrice(asset);
        uint8 dec = IAggregatorV3(feed).decimals();
        feeds[asset] = FeedConfig({feed: feed, heartbeat: heartbeat, feedDecimals: dec, set: true});
        emit FeedSet(asset, feed, heartbeat, dec);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Guardian/owner triggers or lifts the circuit breaker for an asset (called when off-chain monitoring detects a depeg or deviation anomaly).
    function setPaused(address asset, bool isPaused_) external onlyGuardianOrOwner {
        paused[asset] = isPaused_;
        emit PausedSet(asset, isPaused_);
    }

    /*//////////////////////////////////////////////////////////////
                                PRICE FETCH
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256) {
        FeedConfig memory cfg = feeds[asset];
        if (!cfg.set) revert FeedNotSet(asset);

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(cfg.feed).latestRoundData();

        // Sanity: price must be positive
        if (answer <= 0) revert InvalidPrice(asset);
        // Staleness: reject if price exceeds heartbeat age (even liquidations must wait for a fresh price)
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

    /// @inheritdoc IPriceOracle
    function isPaused(address asset) external view returns (bool) {
        return paused[asset];
    }
}
