// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {IBellGuardCallback} from "./interfaces/IBellGuardCallback.sol";

/// @title BellGuardReactive
/// @notice Runs on Reactive Network. Watches every price print Bell lending markets record on Base and wakes
///         BellGuard the moment a print falls.
///
///         Bell prices stock collateral with two prints: liquidations use the higher of the last two, so a single
///         falling print can never liquidate anyone; the next print has to confirm it. That leaves one print of
///         warning. This contract turns the warning into action: it keeps the last print of every (market, stock)
///         pair it watches, and when a new print is lower than the last one by at least `minDropBps`, it asks the
///         network to call BellGuard on Base, which deleverages protected borrowers before the confirming print.
///         Rising and flat prints only update the record.
///
///         It also listens to the guard itself: if a sweep runs low on gas, the guard emits `SweepPaused` and this
///         contract immediately requests another callback for the same print, so the guard never has to choose
///         between protecting everyone and fitting in one transaction.
contract BellGuardReactive is AbstractReactive {
    /// @notice `BellMarket.Observed(address indexed token, uint80 roundId, int256 answer)`.
    uint256 public constant OBSERVED_TOPIC_0 = uint256(keccak256("Observed(address,uint80,int256)"));
    /// @notice `BellGuard.SweepPaused(...)`: the guard ran low on gas mid-sweep and wants the rest of it.
    uint256 public constant SWEEP_PAUSED_TOPIC_0 =
        uint256(keccak256("SweepPaused(address,address,uint80,int256,int256,uint256,uint256)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 3_000_000;
    uint256 internal constant BPS = 10_000;

    struct Print {
        uint80 roundId;
        int256 answer;
    }

    uint256 public immutable originChainId;
    address public owner;
    address public guard;
    uint16 public minDropBps;

    mapping(address market => mapping(address token => Print)) public lastPrint;
    uint256 public printsSeen;
    uint256 public callbacksRequested;
    uint256 public continuations;

    event OwnerChanged(address indexed owner);
    event GuardSet(address indexed guard);
    event MinDropSet(uint16 minDropBps);
    event Watching(address indexed market, address indexed token);
    event Unwatched(address indexed market, address indexed token);
    event FallingPrint(
        address indexed market,
        address indexed token,
        uint80 roundId,
        int256 prevAnswer,
        int256 answer,
        uint256 dropBps,
        uint256 originBlock
    );
    event SweepContinued(address indexed market, address indexed token, uint80 roundId, uint256 nextIndex);

    error NotOwner();
    error LengthMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param originChainId_ Chain the markets and the guard live on (84532 for Base Sepolia).
    /// @param guard_ BellGuard on the origin chain; may be zero and set later.
    /// @param minDropBps_ Smallest fall, in basis points of the previous print, that wakes the guard.
    /// @param markets_ Bell markets to watch, paired with `tokens_`.
    /// @param tokens_ Stock to watch in the paired market, or zero for every stock the market lists.
    constructor(
        uint256 originChainId_,
        address guard_,
        uint16 minDropBps_,
        address[] memory markets_,
        address[] memory tokens_
    ) payable {
        if (markets_.length != tokens_.length) revert LengthMismatch();
        owner = msg.sender;
        originChainId = originChainId_;
        minDropBps = minDropBps_;
        emit OwnerChanged(msg.sender);
        emit MinDropSet(minDropBps_);
        _setGuard(guard_);
        for (uint256 i; i < markets_.length; ++i) {
            _subscribe(markets_[i], tokens_[i], true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REACTIVE
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by the system contract for every `Observed` log on a watched market, and for every
    ///         `SweepPaused` log from the guard.
    function react(LogRecord calldata log_) external onlySystem {
        // Anything that is not a well-formed log from the origin chain falls through; reverting would still be
        // billed.
        if (log_.chainId != originChainId) return;
        if (log_.topic0 == OBSERVED_TOPIC_0 && log_.opCode == 2) _onPrint(log_);
        else if (log_.topic0 == SWEEP_PAUSED_TOPIC_0 && log_.opCode == 3 && log_.contractAddress == guard) {
            _onSweepPaused(log_);
        }
    }

    function _onPrint(LogRecord calldata log_) internal {
        address market = log_.contractAddress;
        address token = address(uint160(log_.topic1));
        (uint80 roundId, int256 answer) = abi.decode(log_.data, (uint80, int256));

        Print storage last = lastPrint[market][token];
        if (roundId <= last.roundId) return;
        int256 prev = last.answer;
        last.roundId = roundId;
        last.answer = answer;
        ++printsSeen;

        if (prev <= 0 || answer >= prev || guard == address(0)) return;
        uint256 dropBps = uint256(prev - answer) * BPS / uint256(prev);
        if (dropBps < minDropBps) return;

        emit FallingPrint(market, token, roundId, prev, answer, dropBps, log_.blockNumber);
        _callGuard(market, token, roundId, prev, answer, log_.blockNumber);
    }

    /// @dev The guard could not finish a sweep in one callback; ask for the rest of it, for the same print.
    function _onSweepPaused(LogRecord calldata log_) internal {
        address market = address(uint160(log_.topic1));
        address token = address(uint160(log_.topic2));
        (uint80 roundId, int256 prev, int256 answer, uint256 originBlock, uint256 nextIndex) =
            abi.decode(log_.data, (uint80, int256, int256, uint256, uint256));
        ++continuations;
        emit SweepContinued(market, token, roundId, nextIndex);
        _callGuard(market, token, roundId, prev, answer, originBlock);
    }

    function _callGuard(address market, address token, uint80 roundId, int256 prev, int256 answer, uint256 originBlock)
        internal
    {
        ++callbacksRequested;
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: guard,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(
                    IBellGuardCallback.onFallingPrint,
                    (address(0), market, token, roundId, prev, answer, originBlock, block.number, block.timestamp)
                )
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Starts watching `token` in `market` (zero `token` = every stock the market lists).
    function watch(address market, address token) external onlyOwner {
        _subscribe(market, token, true);
    }

    function unwatch(address market, address token) external onlyOwner {
        _subscribe(market, token, false);
    }

    function setGuard(address guard_) external onlyOwner {
        _setGuard(guard_);
    }

    function setMinDropBps(uint16 minDropBps_) external onlyOwner {
        minDropBps = minDropBps_;
        emit MinDropSet(minDropBps_);
    }

    function transferOwnership(address owner_) external onlyOwner {
        owner = owner_;
        emit OwnerChanged(owner_);
    }

    /// @notice Returns REACT held by this contract (not reserves held by the system contract).
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _pay(to, amount);
    }

    /// @notice Settles any debt to the system contract from this contract's balance; anyone may call it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @dev Points callbacks at `guard_` and listens for its SweepPaused events instead of the old guard's.
    function _setGuard(address guard_) internal {
        address old = guard;
        if (old != address(0)) {
            SYSTEM.unsubscribe(
                originChainId, old, SWEEP_PAUSED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        guard = guard_;
        if (guard_ != address(0)) {
            SYSTEM.subscribe(
                originChainId, guard_, SWEEP_PAUSED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        emit GuardSet(guard_);
    }

    function _subscribe(address market, address token, bool on) internal {
        uint256 topic1 = token == address(0) ? REACTIVE_IGNORE : uint256(uint160(token));
        if (on) {
            SYSTEM.subscribe(originChainId, market, OBSERVED_TOPIC_0, topic1, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit Watching(market, token);
        } else {
            SYSTEM.unsubscribe(originChainId, market, OBSERVED_TOPIC_0, topic1, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit Unwatched(market, token);
        }
    }
}
