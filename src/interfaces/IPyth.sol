// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Pyth interface (only the functions this protocol uses).
/// @dev Mirrors the layout of PythStructs.Price so ABI decoding against the real Pyth
///      contract (Arc testnet: 0x2880aB155794e7179c9eE2e38200202908C17B43) is identical.
///      Kept minimal on purpose, matching the IAggregatorV3 convention (no full SDK import).
interface IPyth {
    /// @dev Tuple layout (int64, uint64, int32, uint256), verified against on-chain getPriceUnsafe.
    struct Price {
        int64 price; // price value
        uint64 conf; // confidence interval (uncertainty)
        int32 expo; // exponent: real value = price * 10^expo (USD crypto feeds use -8)
        uint256 publishTime; // unix timestamp of the update
    }

    /// @notice Latest price WITHOUT staleness revert (caller checks publishTime). Used here so the
    ///         oracle can surface the protocol's own StalePrice error, consistent with ChainlinkPriceOracle.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Latest price, reverting (with Pyth's own error) if older than `age` seconds.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);

    /// @notice Fee (in wei) required to submit a given batch of price update data. Query before updatePriceFeeds.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Submit Hermes-signed price updates on-chain (pull model). Attach getUpdateFee as msg.value.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
