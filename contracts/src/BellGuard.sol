// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {StdPredeploys} from "base-std/StdPredeploys.sol";
import {BellMarket} from "bell/BellMarket.sol";
import {IBellGuardCallback} from "./interfaces/IBellGuardCallback.sol";

/// @title BellGuard
/// @notice Deleverages Bell borrowers inside the one-print warning Bell gives them.
///
///         Bell liquidates on the higher of a stock's last two prints, so after a falling print nobody can be
///         liquidated until the next print confirms it. At that moment the market already knows the worst case:
///         every position valued at the lower print. A borrower opts in with a trigger and a target health factor
///         and a budget in the market's asset. When BellGuardReactive reports a falling print, this contract
///         values each protected position at the lower print (its "pessimistic" health factor, the one a
///         confirming print would make real) and, if that is below the trigger, repays debt from the borrower's
///         own wallet until the pessimistic health factor is back at the target, before the confirming print can
///         arrive.
///
///         The guard never holds user funds between calls: it pulls exactly what it repays, inside the same
///         transaction, from an allowance the borrower granted. Accounts are handled independently, so one
///         borrower's missing allowance cannot block another's protection.
contract BellGuard is AbstractCallback, IBellGuardCallback {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @notice Protected accounts per market.
    uint256 public constant MAX_ACCOUNTS = 32;
    /// @notice A sweep stops before an account when less gas than this is left, and asks for a continuation.
    uint256 public constant SWEEP_GAS_RESERVE = 400_000;

    struct Protection {
        uint64 triggerHf; // WAD; act when the pessimistic health factor is below this
        uint64 targetHf; // WAD; repay until the pessimistic health factor is back at this
        uint128 budget; // most the guard may pull from the account, in the market's asset, since `protect`
        uint128 spent;
    }

    /// @notice Where a paused sweep resumes: the print it belongs to and the next account index.
    struct Cursor {
        address token;
        uint80 roundId;
        uint32 next;
    }

    struct Quote {
        bool loaded;
        bool ok;
        uint16 thresholdBps;
        uint256 low;
        uint256 scale;
    }

    address public owner;
    mapping(address market => bool) public marketAllowed;
    mapping(address market => mapping(address account => Protection)) public protectionOf;
    mapping(address market => address[]) internal _accounts;
    mapping(address market => mapping(address account => uint256)) internal _slot; // index + 1
    mapping(address market => Cursor) public cursorOf;

    uint256 public printsHandled;
    uint256 public rescues;

    event OwnerChanged(address indexed owner);
    event MarketAllowed(address indexed market, bool allowed);
    event Protected(address indexed market, address indexed account, uint64 triggerHf, uint64 targetHf, uint128 budget);
    event Unprotected(address indexed market, address indexed account);
    /// @notice One per callback: the full-loop trace (origin print -> Reactive -> this transaction).
    /// @param handledAtMs This block's timestamp in milliseconds (Base's BaseTime predeploy).
    event PrintHandled(
        address indexed market,
        address indexed token,
        uint80 roundId,
        int256 prevAnswer,
        int256 answer,
        uint256 originBlock,
        uint256 reactiveBlock,
        uint256 reactiveTimestamp,
        uint64 handledAtMs,
        uint256 checked,
        uint256 rescued
    );
    event Guarded(
        address indexed market,
        address indexed account,
        address indexed token,
        uint80 roundId,
        uint256 repaid,
        uint256 healthBefore,
        uint256 healthAfter
    );
    event GuardFailed(address indexed market, address indexed account, uint80 roundId, uint256 wanted, bytes reason);
    /// @notice The sweep for this print ran low on gas before `nextIndex`. BellGuardReactive listens for this and
    ///         requests another callback for the same print, which resumes there.
    event SweepPaused(
        address indexed market,
        address indexed token,
        uint80 roundId,
        int256 prevAnswer,
        int256 answer,
        uint256 originBlock,
        uint256 nextIndex
    );

    error NotOwner();
    error OnlySelf();
    error BadParams();
    error MarketNotAllowed(address market);
    error TooManyAccounts(address market);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ Reactive Network callback proxy on this chain.
    /// @param reactive_ The BellGuardReactive contract allowed to call `onFallingPrint`.
    constructor(IPayable callbackProxy_, address reactive_) payable AbstractCallback(callbackProxy_, reactive_) {
        owner = msg.sender;
        emit OwnerChanged(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               BORROWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Opts the caller's position in `market` into protection, or updates it. Also approve this contract
    ///         to spend the market's asset (at least `budget`); `spent` restarts from zero.
    /// @param triggerHf Act when the pessimistic health factor (WAD) falls below this. Must be above 1.
    /// @param targetHf Repay until the pessimistic health factor is back at this. Must be above `triggerHf`.
    /// @param budget Most the guard may repay from the caller's wallet in total.
    function protect(address market, uint64 triggerHf, uint64 targetHf, uint128 budget) external {
        if (!marketAllowed[market]) revert MarketNotAllowed(market);
        if (triggerHf <= WAD || targetHf <= triggerHf || targetHf > 5 * WAD || budget == 0) revert BadParams();
        if (_slot[market][msg.sender] == 0) {
            if (_accounts[market].length >= MAX_ACCOUNTS) revert TooManyAccounts(market);
            _accounts[market].push(msg.sender);
            _slot[market][msg.sender] = _accounts[market].length;
        }
        protectionOf[market][msg.sender] = Protection(triggerHf, targetHf, budget, 0);
        emit Protected(market, msg.sender, triggerHf, targetHf, budget);
    }

    function unprotect(address market) external {
        _remove(market, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBellGuardCallback
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
    ) external onlyServiceProvider onlyCallbackSender(reactive) {
        uint64 handledAtMs = _nowMs();
        uint256 checked;
        uint256 rescued;
        uint256 pausedAt;
        if (marketAllowed[market]) (checked, rescued, pausedAt) = _sweep(market, token, roundId);
        ++printsHandled;
        rescues += rescued;
        emit PrintHandled(
            market,
            token,
            roundId,
            prevAnswer,
            answer,
            originBlock,
            reactiveBlock,
            reactiveTimestamp,
            handledAtMs,
            checked,
            rescued
        );
        if (pausedAt != 0) emit SweepPaused(market, token, roundId, prevAnswer, answer, originBlock, pausedAt);
    }

    /// @dev Repays `amount` of `account`'s debt with `account`'s own funds. External only so `_sweep` can isolate
    ///      each account with try/catch.
    function repayFor(address market, address account, uint256 amount) external returns (uint256 paid) {
        if (msg.sender != address(this)) revert OnlySelf();
        BellMarket m = BellMarket(market);
        IB20 asset = m.asset();
        asset.transferFrom(account, address(this), amount);
        if (asset.allowance(address(this), market) < amount) asset.approve(market, type(uint256).max);
        paid = m.repay(amount, account);
        if (paid < amount) asset.transfer(account, amount - paid);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function accountsOf(address market) external view returns (address[] memory) {
        return _accounts[market];
    }

    /// @notice Health factor (WAD) the account would have if the lower of each stock's last two prints were
    ///         confirmed: what a liquidator would see one print from now. `type(uint256).max` without debt.
    function pessimisticHealthOf(address market, address account) external view returns (uint256) {
        BellMarket m = BellMarket(market);
        uint256 debt = m.debtOf(account);
        if (debt == 0) return type(uint256).max;
        address[] memory tokens = m.collaterals();
        Quote[] memory quotes = new Quote[](tokens.length);
        (uint256 v, bool ok) = _lowValue(m, account, tokens, quotes, 10 ** uint256(m.assetDecimals()));
        return ok ? v * WAD / debt : 0;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    function allowMarket(address market, bool allowed) external onlyOwner {
        marketAllowed[market] = allowed;
        emit MarketAllowed(market, allowed);
    }

    /// @notice Removes an account, e.g. one squatting a slot with a position that holds nothing.
    function evict(address market, address account) external onlyOwner {
        _remove(market, account);
    }

    function transferOwnership(address owner_) external onlyOwner {
        owner = owner_;
        emit OwnerChanged(owner_);
    }

    /// @notice Returns ETH held by this contract (the callback proxy's reserves are separate).
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _pay(to, amount);
    }

    /// @notice Settles any debt to the callback proxy from this contract's balance; anyone may call it.
    function coverDebt() external {
        _coverDebt();
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @return checked Accounts holding the fallen stock that were evaluated.
    /// @return rescued Accounts the guard repaid debt for.
    /// @return pausedAt Index to resume from if gas ran low (0 when the sweep finished).
    function _sweep(address market, address token, uint80 roundId)
        internal
        returns (uint256 checked, uint256 rescued, uint256 pausedAt)
    {
        address[] memory accounts = _accounts[market];
        Cursor memory cursor = cursorOf[market];
        uint256 start = cursor.token == token && cursor.roundId == roundId ? cursor.next : 0;
        if (start != 0 || cursor.next != 0) delete cursorOf[market];
        if (start >= accounts.length) return (0, 0, 0);
        BellMarket m = BellMarket(market);
        address[] memory tokens = m.collaterals();
        Quote[] memory quotes = new Quote[](tokens.length);
        uint256 assetUnit = 10 ** uint256(m.assetDecimals());

        for (uint256 i = start; i < accounts.length; ++i) {
            // Stop while there is still room to finish cleanly; a reverted callback would rescue nobody.
            if (i > start && gasleft() < SWEEP_GAS_RESERVE) {
                cursorOf[market] = Cursor(token, roundId, uint32(i));
                return (checked, rescued, i);
            }
            address account = accounts[i];
            // Only positions holding the stock that fell can have become riskier.
            if (m.collateralOf(account, token) == 0) continue;
            ++checked;
            if (_rescue(m, account, token, roundId, tokens, quotes, assetUnit)) ++rescued;
        }
    }

    function _rescue(
        BellMarket m,
        address account,
        address token,
        uint80 roundId,
        address[] memory tokens,
        Quote[] memory quotes,
        uint256 assetUnit
    ) internal returns (bool) {
        address market = address(m);
        uint256 debt = m.debtOf(account);
        if (debt == 0) return false;
        (uint256 v, bool ok) = _lowValue(m, account, tokens, quotes, assetUnit);
        if (!ok) {
            emit GuardFailed(market, account, roundId, 0, "price unavailable");
            return false;
        }
        uint256 health = v * WAD / debt;
        Protection memory p = protectionOf[market][account];
        if (health >= p.triggerHf) return false;

        uint256 keep = v * WAD / p.targetHf;
        uint256 want = debt > keep ? debt - keep : 0;
        uint256 room = p.budget - p.spent;
        if (want > room) want = room;
        IB20 asset = m.asset();
        uint256 avail = asset.allowance(account, address(this));
        uint256 bal = asset.balanceOf(account);
        if (bal < avail) avail = bal;
        if (want > avail) want = avail;
        if (want == 0) {
            emit GuardFailed(market, account, roundId, 0, "no budget, allowance or balance");
            return false;
        }
        try this.repayFor(market, account, want) returns (uint256 paid) {
            protectionOf[market][account].spent = uint128(p.spent + paid);
            uint256 debtAfter = debt - paid;
            emit Guarded(
                market, account, token, roundId, paid, health, debtAfter == 0 ? type(uint256).max : v * WAD / debtAfter
            );
            return true;
        } catch (bytes memory reason) {
            emit GuardFailed(market, account, roundId, want, reason);
            return false;
        }
    }

    /// @dev Collateral at the lower of each stock's last two prints, times its liquidation threshold, in asset
    ///      units. Prices are loaded once per stock per call and cached in `quotes`.
    function _lowValue(BellMarket m, address account, address[] memory tokens, Quote[] memory quotes, uint256 assetUnit)
        internal
        view
        returns (uint256 v, bool ok)
    {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 bal = m.collateralOf(account, tokens[i]);
            if (bal == 0) continue;
            if (!quotes[i].loaded) quotes[i] = _quote(m, tokens[i]);
            Quote memory q = quotes[i];
            if (!q.ok) return (0, false);
            v += bal * q.low * assetUnit / q.scale * q.thresholdBps / BPS;
        }
        return (v, true);
    }

    function _quote(BellMarket m, address token) internal view returns (Quote memory q) {
        q.loaded = true;
        try m.priceOf(token) returns (BellMarket.PriceView memory p) {
            (,, uint16 threshold,,,) = m.configOf(token);
            q.ok = true;
            q.thresholdBps = threshold;
            q.low = p.low;
            q.scale = 10 ** (uint256(IB20(token).decimals()) + p.decimals);
        } catch {}
    }

    function _remove(address market, address account) internal {
        uint256 slot = _slot[market][account];
        if (slot == 0) return;
        address[] storage list = _accounts[market];
        address moved = list[list.length - 1];
        list[slot - 1] = moved;
        _slot[market][moved] = slot;
        list.pop();
        delete _slot[market][account];
        delete protectionOf[market][account];
        emit Unprotected(market, account);
    }

    /// @dev Block time in milliseconds from Base's BaseTime predeploy (200 ms blocks), seconds x 1000 elsewhere.
    function _nowMs() internal view returns (uint64) {
        if (address(StdPredeploys.BASE_TIME).code.length == 0) return uint64(block.timestamp) * 1000;
        return StdPredeploys.BASE_TIME.timestampMs();
    }
}
