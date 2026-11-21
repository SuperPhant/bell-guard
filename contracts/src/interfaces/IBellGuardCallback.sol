// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice The callback BellGuardReactive sends to BellGuard on the origin chain.
interface IBellGuardCallback {
    /// @param reactive Overwritten by the callback proxy with the address of the reactive contract that requested
    ///        the callback; the guard only accepts its own reactive contract.
    /// @param market Bell market that observed the print.
    /// @param token Stock whose price fell.
    /// @param roundId Feed round of the falling print.
    /// @param prevAnswer The stock's previous print, as the reactive contract saw it.
    /// @param answer The falling print.
    /// @param originBlock Origin-chain block of the print (`LogRecord.blockNumber`).
    /// @param reactiveBlock Reactive Network block in which `react()` ran.
    /// @param reactiveTimestamp Reactive Network block timestamp (seconds) in which `react()` ran.
    function onFallingPrint(
        address reactive,
        address market,
        address token,
        uint80 roundId,
        int256 prevAnswer,
        int256 answer,
        uint256 originBlock,
        uint256 reactiveBlock,
        uint256 reactiveTimestamp
    ) external;
}
