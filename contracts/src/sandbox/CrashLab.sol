// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IB20} from "base-std/interfaces/IB20.sol";
import {StdPredeploys} from "base-std/StdPredeploys.sol";
import {BellMarket} from "bell/BellMarket.sol";
import {MirrorFeedHub} from "bell/testnet/MirrorFeedHub.sol";
import {BellGuard} from "../BellGuard.sol";
import {DemoBorrower} from "./DemoBorrower.sol";

/// @title CrashLab
/// @notice Sandbox for showing BellGuard work on Base Sepolia. It owns the price feed of a separate Bell market
///         (same contract as the live one), so it can stage a crash on demand:
///
///         1. `openPair` opens two identical borrowers at the market's borrowing limit.
///         2. `arm` protects one of them with BellGuard.
///         3. `print` publishes a falling print (the warning). BellGuardReactive sees it on Reactive Network and
///            calls BellGuard back on Base, which deleverages the protected borrower.
///         4. `confirmAndLiquidate` publishes the confirming print and immediately tries to liquidate both.
///
///         Every print and every liquidation attempt is logged with Base's millisecond block time, so the race
///         between the guard and the confirming print can be read straight from the chain.
contract CrashLab {
    struct Pair {
        address token;
        DemoBorrower guarded;
        DemoBorrower unguarded;
    }

    BellMarket public immutable market;
    MirrorFeedHub public immutable hub;
    BellGuard public immutable guard;
    IB20 public immutable usd;
    address public owner;

    mapping(address token => uint256) internal _feedSlot; // feed id + 1
    uint80 public round;
    Pair[] internal _pairs;

    event OwnerChanged(address indexed owner);
    event StockAdded(address indexed token, uint256 feedId);
    event Printed(address indexed token, uint80 roundId, int256 answer, uint64 atMs);
    event PairOpened(
        uint256 indexed pairId, address indexed token, address guarded, address unguarded, uint256 units, uint256 debt
    );
    event Armed(uint256 indexed pairId, address indexed guarded, uint64 triggerHf, uint64 targetHf, uint128 budget);
    event BorrowerCreated(address indexed borrower);
    event LiquidationAttempt(
        uint256 indexed pairId,
        address indexed account,
        bool liquidated,
        uint256 healthBefore,
        uint256 repaid,
        uint256 seized,
        uint64 atMs
    );

    error NotOwner();
    error UnknownStock(address token);
    error UnknownPair(uint256 pairId);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev After deployment the hub's owner makes this contract the hub's relayer, and the stock tokens and the
    ///      market's asset grant it MINT_ROLE (it mints the borrowers' collateral and the liquidator's cash).
    constructor(BellMarket market_, MirrorFeedHub hub_, BellGuard guard_, uint80 firstRound_) {
        market = market_;
        hub = hub_;
        guard = guard_;
        usd = market_.asset();
        owner = msg.sender;
        round = firstRound_;
        emit OwnerChanged(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    function addStock(address token, uint256 feedId) external onlyOwner {
        _feedSlot[token] = feedId + 1;
        emit StockAdded(token, feedId);
    }

    /// @notice Publishes a new round for `token` at the current time and records it in the market, which emits
    ///         the `Observed` event BellGuardReactive listens to.
    function print(address token, int256 answer) public onlyOwner returns (uint64 atMs) {
        uint256 slot = _feedSlot[token];
        if (slot == 0) revert UnknownStock(token);
        uint256[] memory ids = new uint256[](1);
        uint80[] memory rounds = new uint80[](1);
        int256[] memory answers = new int256[](1);
        uint64[] memory ts = new uint64[](1);
        ids[0] = slot - 1;
        rounds[0] = ++round;
        answers[0] = answer;
        ts[0] = uint64(block.timestamp);
        hub.relay(ids, rounds, answers, ts, ts);
        market.poke(token);
        atMs = _nowMs();
        emit Printed(token, round, answer, atMs);
    }

    /// @notice Opens two identical positions: `units` of `token` each, borrowing everything the market allows.
    ///         Both also receive `reserve` of the market's asset, kept in their wallets.
    function openPair(address token, uint256 units, uint256 reserve) external onlyOwner returns (uint256 pairId) {
        if (_feedSlot[token] == 0) revert UnknownStock(token);
        DemoBorrower g = new DemoBorrower();
        DemoBorrower u = new DemoBorrower();
        uint256 debt = _open(g, token, units, reserve);
        _open(u, token, units, reserve);
        pairId = _pairs.length;
        _pairs.push(Pair(token, g, u));
        emit PairOpened(pairId, token, address(g), address(u), units, debt);
    }

    /// @notice Protects the pair's guarded borrower: approves BellGuard for `budget` and opts in.
    function arm(uint256 pairId, uint64 triggerHf, uint64 targetHf, uint128 budget) external onlyOwner {
        Pair memory p = pairOf(pairId);
        p.guarded.exec(address(usd), abi.encodeCall(IB20.approve, (address(guard), budget)));
        p.guarded.exec(address(guard), abi.encodeCall(BellGuard.protect, (address(market), triggerHf, targetHf, budget)));
        emit Armed(pairId, address(p.guarded), triggerHf, targetHf, budget);
    }

    /// @notice Publishes the confirming print, then tries to liquidate both borrowers of the pair at once, the
    ///         way a liquidation bot would.
    function confirmAndLiquidate(uint256 pairId, int256 answer) external onlyOwner {
        Pair memory p = pairOf(pairId);
        print(p.token, answer);
        _tryLiquidate(pairId, p.token, address(p.guarded));
        _tryLiquidate(pairId, p.token, address(p.unguarded));
    }

    /// @notice Takes the pair's guarded borrower out of BellGuard once its run is over, freeing the slot.
    function disarm(uint256 pairId) external onlyOwner {
        Pair memory p = pairOf(pairId);
        p.guarded.exec(address(guard), abi.encodeCall(BellGuard.unprotect, (address(market))));
    }

    /// @notice A borrower account the owner drives through `act`, e.g. a protected position on the live market.
    function newBorrower() external onlyOwner returns (DemoBorrower b) {
        b = new DemoBorrower();
        emit BorrowerCreated(address(b));
    }

    function act(DemoBorrower b, address target, bytes calldata data) external onlyOwner returns (bytes memory) {
        return b.exec(target, data);
    }

    /// @notice Mints a test token this lab holds MINT_ROLE on (the sandbox stocks and tUSD).
    function mint(address token, address to, uint256 amount) external onlyOwner {
        IB20(token).mint(to, amount);
    }

    function transferOwnership(address owner_) external onlyOwner {
        owner = owner_;
        emit OwnerChanged(owner_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function pairCount() external view returns (uint256) {
        return _pairs.length;
    }

    function pairOf(uint256 pairId) public view returns (Pair memory) {
        if (pairId >= _pairs.length) revert UnknownPair(pairId);
        return _pairs[pairId];
    }

    function feedIdOf(address token) external view returns (uint256) {
        uint256 slot = _feedSlot[token];
        if (slot == 0) revert UnknownStock(token);
        return slot - 1;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _open(DemoBorrower b, address token, uint256 units, uint256 reserve) internal returns (uint256 debt) {
        IB20(token).mint(address(b), units);
        if (reserve != 0) usd.mint(address(b), reserve);
        b.exec(token, abi.encodeCall(IB20.approve, (address(market), units)));
        b.exec(address(market), abi.encodeCall(BellMarket.depositCollateral, (token, units)));
        debt = market.borrowPowerOf(address(b));
        b.exec(address(market), abi.encodeCall(BellMarket.borrow, (debt)));
    }

    function _tryLiquidate(uint256 pairId, address token, address account) internal {
        uint256 health = market.healthFactorOf(account);
        uint256 debt = market.debtOf(account);
        uint256 repay = debt * market.CLOSE_FACTOR_BPS() / 10_000;
        if (repay == 0) {
            emit LiquidationAttempt(pairId, account, false, health, 0, 0, _nowMs());
            return;
        }
        usd.mint(address(this), repay);
        usd.approve(address(market), repay);
        try market.liquidate(account, token, repay) returns (uint256 seized) {
            emit LiquidationAttempt(pairId, account, true, health, repay, seized, _nowMs());
        } catch {
            usd.approve(address(market), 0);
            emit LiquidationAttempt(pairId, account, false, health, 0, 0, _nowMs());
        }
    }

    function _nowMs() internal view returns (uint64) {
        if (address(StdPredeploys.BASE_TIME).code.length == 0) return uint64(block.timestamp) * 1000;
        return StdPredeploys.BASE_TIME.timestampMs();
    }
}
