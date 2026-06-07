// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {StalePrice, InvalidPrice, FeedNotSet, NotAuthorized, ZeroAddress} from "./libraries/DataTypes.sol";

/// @title PriceOracle
/// @notice Chainlink 价格聚合 + Layer 2 熔断（architecture.md §四.6 / §七）。
///         方案 B：链上只做 staleness + sanity（纯 view）；偏差(脱锚)监控在链下，
///         guardian 发现异常调 setPaused。暂停只挡新 borrow/deposit，repay/liquidate 不受影响。
/// @dev 价格统一归一到 1e8 USD base。即使是 USDC 也走 feed（不硬编码 = 1），
///      否则永远无法观测 USDC 脱锚——而脱锚正是 §七 的核心尾部风险。
contract PriceOracle is IPriceOracle, Ownable {
    struct FeedConfig {
        address feed; // Chainlink aggregator
        uint32 heartbeat; // 最大可接受陈旧秒数（超过即 stale）
        uint8 feedDecimals; // feed 报价精度（缓存，省一次外部 call）
        bool set; // 是否已配置
    }

    /// @notice 资产 => feed 配置。
    mapping(address asset => FeedConfig) public feeds;

    /// @notice 资产 => 是否熔断暂停。
    mapping(address asset => bool) public paused;

    /// @notice 可触发暂停的热钱包（与 admin 分离，便于快速响应脱锚）。
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
                              admin / guardian
    //////////////////////////////////////////////////////////////*/

    /// @notice 配置某资产的 Chainlink feed + 心跳。feed 精度从合约现读现缓存。
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

    /// @notice guardian/owner 熔断或恢复某资产（链下监测到脱锚/偏差异常时调用）。
    function setPaused(address asset, bool isPaused_) external onlyGuardianOrOwner {
        paused[asset] = isPaused_;
        emit PausedSet(asset, isPaused_);
    }

    /*//////////////////////////////////////////////////////////////
                                取价
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256) {
        FeedConfig memory cfg = feeds[asset];
        if (!cfg.set) revert FeedNotSet(asset);

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(cfg.feed).latestRoundData();

        // sanity：价格必须为正
        if (answer <= 0) revert InvalidPrice(asset);
        // staleness：超过心跳即拒绝（即便 liquidate 也不接受陈旧价 → 等新价）
        if (block.timestamp - updatedAt > cfg.heartbeat) revert StalePrice(cfg.feed);

        // answer 已确保 > 0，转 uint256 恒安全
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);

        // 归一到 1e8 USD base
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
