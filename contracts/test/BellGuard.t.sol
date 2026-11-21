// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";

import {BellMarket} from "bell/BellMarket.sol";
import {MirrorFeedHub} from "bell/testnet/MirrorFeedHub.sol";
import {MirrorOracleRegistry} from "bell/testnet/MirrorOracleRegistry.sol";
import {AggregatorV3Interface} from "bell/interfaces/AggregatorV3Interface.sol";
import {IOracleRegistry} from "bell/interfaces/IOracleRegistry.sol";

import {BellGuard} from "../src/BellGuard.sol";
import {BellGuardReactive} from "../src/BellGuardReactive.sol";
import {CrashLab} from "../src/sandbox/CrashLab.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

/// @dev Run against a Base Sepolia fork (B20 precompiles and the BaseTime predeploy):
///      forge test --fork-url https://sepolia.base.org
contract BellGuardTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    bytes32 constant OBSERVED = keccak256("Observed(address,uint80,int256)");
    uint256 constant WAD = 1e18;

    address proxy = makeAddr("callbackProxy");
    MockSystem sys;
    MirrorFeedHub hub;
    BellMarket market;
    IB20 usd;
    IB20 tsla;
    IB20 nvda;
    address tslaAdapter;
    address nvdaAdapter;
    BellGuardReactive rx;
    BellGuard guard;
    CrashLab lab;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));

        hub = new MirrorFeedHub(address(this));
        MirrorOracleRegistry registry = new MirrorOracleRegistry(address(this));
        usd = _stablecoin();
        tsla = _stock("TSLA");
        nvda = _stock("NVDA");
        uint256 tslaFeed;
        uint256 nvdaFeed;
        (tslaFeed, tslaAdapter) = hub.addFeed(address(0), 8, "TSLA / USD");
        (nvdaFeed, nvdaAdapter) = hub.addFeed(address(0), 8, "NVDA / USD");
        _relay(tslaFeed, 1, 400e8);
        _relay(nvdaFeed, 1, 180e8);

        market = new BellMarket(usd, IOracleRegistry(address(registry)), 0.02e27, 0.2e27);
        market.listCollateral(address(tsla), AggregatorV3Interface(tslaAdapter), 4000, 5500, 750, 26 hours);
        market.listCollateral(address(nvda), AggregatorV3Interface(nvdaAdapter), 4000, 5500, 750, 26 hours);
        usd.mint(address(this), 10_000_000e6);
        usd.approve(address(market), type(uint256).max);
        market.supply(10_000_000e6);

        address[] memory markets = new address[](1);
        address[] memory tokens = new address[](1);
        markets[0] = address(market);
        rx = new BellGuardReactive(block.chainid, address(0), 0, markets, tokens);
        guard = new BellGuard(IPayable(payable(proxy)), address(rx));
        rx.setGuard(address(guard));
        guard.allowMarket(address(market), true);

        lab = new CrashLab(market, hub, guard, 1);
        hub.setRelayer(address(lab));
        lab.addStock(address(tsla), tslaFeed);
        lab.addStock(address(nvda), nvdaFeed);
        usd.grantRole(B20Constants.MINT_ROLE, address(lab));
        tsla.grantRole(B20Constants.MINT_ROLE, address(lab));
        nvda.grantRole(B20Constants.MINT_ROLE, address(lab));
    }

    /*//////////////////////////////////////////////////////////////
                                THE LOOP
    //////////////////////////////////////////////////////////////*/

    function test_fullLoop_guardDeleveragesBeforeTheConfirmingPrint() public {
        uint256 pairId = lab.openPair(address(tsla), 100e8, 10_000e6);
        CrashLab.Pair memory p = lab.pairOf(pairId);
        address g = address(p.guarded);
        address u = address(p.unguarded);
        assertEq(market.debtOf(g), 16_000e6, "borrowed at the limit: $40k x 40%");
        assertEq(_printAndReact(address(tsla), 400e8), 0, "the reactive contract records its first print");

        // A week of selling, confirmed by two prints: health 1.375 -> 1.155.
        assertEq(_printAndReact(address(tsla), 336e8), 1, "first print of the slide wakes the guard");
        _deliver(sys.callbackCount() - 1); // nobody protected yet: a no-op
        assertEq(_printAndReact(address(tsla), 336e8), 0, "flat print");
        assertApproxEqAbs(market.healthFactorOf(g), 1.155e18, 1e12);

        lab.arm(pairId, 1.25e18, 1.40e18, 10_000e6);

        // Monday gap: -15%. Bell still prices liquidations at $336, so nobody can be liquidated yet...
        assertEq(_printAndReact(address(tsla), 285.6e8), 1);
        assertGe(market.healthFactorOf(u), 1e18, "one print cannot liquidate");
        // ...but the guard already sees the worst case: $285.60 confirmed.
        assertApproxEqAbs(guard.pessimisticHealthOf(address(market), g), 0.98175e18, 1e12);
        _deliver(sys.callbackCount() - 1);
        assertEq(market.debtOf(g), 11_220e6, "repaid $4,780 from the borrower's own wallet");
        assertEq(usd.balanceOf(g), 10_000e6 + 16_000e6 - 4_780e6);
        assertGe(guard.pessimisticHealthOf(address(market), g), 1.40e18);
        assertEq(market.debtOf(u), 16_000e6, "the unprotected twin is untouched");
        (,,, uint128 spent) = guard.protectionOf(address(market), g);
        assertEq(spent, 4_780e6);

        // The confirming print lands and a liquidator tries both at once.
        vm.recordLogs();
        lab.confirmAndLiquidate(pairId, 285.6e8);
        (bool gLiquidated, bool uLiquidated) = _liquidationOutcome(vm.getRecordedLogs(), g, u);
        assertFalse(gLiquidated, "guarded borrower survives");
        assertTrue(uLiquidated, "unguarded borrower is liquidated");
        assertApproxEqAbs(market.healthFactorOf(g), 1.40e18, 1e12);
        assertEq(market.collateralOf(g, address(tsla)), 100e8, "kept every share");
        assertLt(market.collateralOf(u, address(tsla)), 100e8, "lost shares plus the 7.5% bonus");
    }

    function test_reactive_onlyFallingPrintsBigEnoughCallBack() public {
        rx.setMinDropBps(50);
        assertEq(_printAndReact(address(tsla), 404e8), 0, "first print seen: just recorded");
        assertEq(_printAndReact(address(tsla), 410e8), 0, "rise");
        assertEq(_printAndReact(address(tsla), 408e8), 0, "-0.49% is below the threshold");
        assertEq(_printAndReact(address(tsla), 405e8), 1, "-0.74% wakes the guard");

        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(sys.callbackCount() - 1);
        assertEq(c.chainId, block.chainid);
        assertEq(c.recipient, address(guard));
        assertEq(c.gasLimit, rx.CALLBACK_GAS_LIMIT());
        (address placeholder, address m, address token, uint80 roundId, int256 prev, int256 answer,,,) =
            abi.decode(_args(c.payload), (address, address, address, uint80, int256, int256, uint256, uint256, uint256));
        assertEq(placeholder, address(0));
        assertEq(m, address(market));
        assertEq(token, address(tsla));
        assertEq(roundId, lab.round());
        assertEq(prev, 408e8);
        assertEq(answer, 405e8);
        assertEq(rx.printsSeen(), 4);
        assertEq(rx.callbacksRequested(), 1);
    }

    function test_reactive_ignoresForeignLogsAndReplays() public {
        _printAndReact(address(tsla), 400e8);
        uint256 next = lab.round() + 1;

        IReactive.LogRecord memory r = _observedRecord(address(tsla), next, 300e8);
        r.chainId = 1;
        vm.prank(SYSTEM);
        rx.react(r);
        r = _observedRecord(address(tsla), next, 300e8);
        r.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(SYSTEM);
        rx.react(r);
        r = _observedRecord(address(tsla), next, 300e8);
        r.opCode = 3;
        vm.prank(SYSTEM);
        rx.react(r);
        assertEq(sys.callbackCount(), 0, "foreign logs ignored");

        r = _observedRecord(address(tsla), next - 1, 300e8);
        vm.prank(SYSTEM);
        rx.react(r);
        assertEq(sys.callbackCount(), 0, "replayed round ignored");

        r = _observedRecord(address(tsla), next, 300e8);
        vm.prank(SYSTEM);
        rx.react(r);
        assertEq(sys.callbackCount(), 1, "the same print with a new round calls back");
    }

    function test_reactive_subscriptions() public {
        assertEq(sys.subscriptionCount(), 2);
        (uint256 chainId, address target, uint256 t0, uint256 t1,,, bool active) = sys.subscriptions(0);
        assertEq(chainId, block.chainid);
        assertEq(target, address(market));
        assertEq(t0, rx.OBSERVED_TOPIC_0());
        assertEq(t1, 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad, "any stock");
        assertTrue(active);
        (chainId, target, t0,,,, active) = sys.subscriptions(1);
        assertEq(target, address(guard), "listens for the guard's SweepPaused");
        assertEq(t0, rx.SWEEP_PAUSED_TOPIC_0());
        assertTrue(active);

        rx.watch(address(0xBE11), address(tsla));
        (,,, t1,,,) = sys.subscriptions(2);
        assertEq(t1, uint256(uint160(address(tsla))));
        rx.unwatch(address(0xBE11), address(tsla));
        (,,,,,, active) = sys.subscriptions(2);
        assertFalse(active);

        rx.setGuard(address(0xC0DE));
        (,,,,,, active) = sys.subscriptions(1);
        assertFalse(active, "old guard dropped");
        (, target,,,,, active) = sys.subscriptions(3);
        assertEq(target, address(0xC0DE));
        assertTrue(active);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BellGuardReactive.NotOwner.selector);
        rx.watch(address(market), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_onlyTheProxyCarryingOurReactiveContractCanCallBack() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), proxy));
        guard.onFallingPrint(address(rx), address(market), address(tsla), 9, 400e8, 300e8, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(rx)));
        vm.prank(proxy);
        guard.onFallingPrint(address(0xBAD), address(market), address(tsla), 9, 400e8, 300e8, 0, 0, 0);

        IReactive.LogRecord memory r = _observedRecord(address(tsla), 9, 300e8);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        rx.react(r);

        vm.expectRevert(BellGuard.OnlySelf.selector);
        guard.repayFor(address(market), address(this), 1);
    }

    function test_protect_validation_limits_and_removal() public {
        vm.expectRevert(abi.encodeWithSelector(BellGuard.MarketNotAllowed.selector, address(0xBE11)));
        guard.protect(address(0xBE11), 1.2e18, 1.4e18, 1);
        vm.expectRevert(BellGuard.BadParams.selector);
        guard.protect(address(market), 1e18, 1.4e18, 1);
        vm.expectRevert(BellGuard.BadParams.selector);
        guard.protect(address(market), 1.4e18, 1.4e18, 1);
        vm.expectRevert(BellGuard.BadParams.selector);
        guard.protect(address(market), 1.2e18, 1.4e18, 0);

        uint256 max = guard.MAX_ACCOUNTS();
        for (uint256 i; i < max; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            guard.protect(address(market), 1.2e18, 1.4e18, 1);
        }
        vm.expectRevert(abi.encodeWithSelector(BellGuard.TooManyAccounts.selector, address(market)));
        guard.protect(address(market), 1.2e18, 1.4e18, 1);

        vm.prank(address(uint160(0x1000)));
        guard.unprotect(address(market));
        guard.protect(address(market), 1.2e18, 1.4e18, 1);
        assertEq(guard.accountsOf(address(market)).length, max);
        assertEq(guard.accountsOf(address(market))[0], address(uint160(0x1000 + max - 1)), "last moved into the gap");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BellGuard.NotOwner.selector);
        guard.evict(address(market), address(this));
        guard.evict(address(market), address(this));
        (uint64 trigger,,,) = guard.protectionOf(address(market), address(this));
        assertEq(trigger, 0);
        assertEq(guard.accountsOf(address(market)).length, max - 1);
    }

    /*//////////////////////////////////////////////////////////////
                         BUDGETS AND ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_budget_allowance_and_failure_isolation() public {
        // Pair 0: guarded with a budget smaller than the rescue needs.
        uint256 pairId = lab.openPair(address(tsla), 100e8, 10_000e6);
        address g = address(lab.pairOf(pairId).guarded);
        lab.arm(pairId, 1.25e18, 1.40e18, 1_000e6);

        // Carol: protected but never approved the guard.
        address carol = makeAddr("carol");
        _openEoa(carol, tsla, 50e8);
        vm.prank(carol);
        guard.protect(address(market), 1.25e18, 1.40e18, 5_000e6);

        // Dave: protected, approved only part of what he needs.
        address dave = makeAddr("dave");
        _openEoa(dave, tsla, 50e8);
        usd.mint(dave, 10_000e6);
        vm.startPrank(dave);
        usd.approve(address(guard), 700e6);
        guard.protect(address(market), 1.25e18, 1.40e18, 5_000e6);
        vm.stopPrank();

        // Erin: protected, but only holds NVDA, which did not fall.
        address erin = makeAddr("erin");
        _openEoa(erin, nvda, 100e8);
        usd.mint(erin, 10_000e6);
        vm.startPrank(erin);
        usd.approve(address(guard), type(uint256).max);
        guard.protect(address(market), 1.25e18, 1.40e18, 5_000e6);
        vm.stopPrank();

        _printAndReact(address(tsla), 400e8);
        _printAndReact(address(tsla), 300e8);
        (Vm.Log[] memory logs,) = _deliverMeasured(sys.callbackCount() - 1, rx.CALLBACK_GAS_LIMIT());

        assertEq(market.debtOf(g), 15_000e6, "budget caps the rescue at $1,000");
        assertEq(market.debtOf(carol), 8_000e6, "no allowance: untouched");
        assertEq(market.debtOf(dave), 8_000e6 - 700e6, "allowance caps the rescue");
        assertEq(market.debtOf(erin), 7_200e6, "NVDA did not fall");

        (uint256 checked, uint256 rescued, uint256 failures) = _sweepSummary(logs);
        assertEq(checked, 3, "only TSLA holders are checked");
        assertEq(rescued, 2);
        assertEq(failures, 1);
        assertEq(guard.rescues(), 2);
        assertEq(guard.printsHandled(), 1);

        // A second fall: the guarded borrower's budget is spent, so nothing more is pulled.
        _printAndReact(address(tsla), 290e8);
        _deliver(sys.callbackCount() - 1);
        assertEq(market.debtOf(g), 15_000e6);
    }

    function test_noRescueAboveTheTrigger() public {
        uint256 pairId = lab.openPair(address(tsla), 100e8, 10_000e6);
        address g = address(lab.pairOf(pairId).guarded);
        lab.arm(pairId, 1.20e18, 1.40e18, 10_000e6);
        _printAndReact(address(tsla), 400e8);
        _printAndReact(address(tsla), 360e8); // pessimistic 1.2375: above the 1.20 trigger
        _deliver(sys.callbackCount() - 1);
        assertEq(market.debtOf(g), 16_000e6);
        assertEq(guard.rescues(), 0);
    }

    /// @dev 32 accounts that all need rescuing do not fit in one callback (the proxy keeps 130k of the 3M limit on
    ///      Base Sepolia). The guard pauses with gas to spare, BellGuardReactive sees `SweepPaused` and requests a
    ///      continuation for the same print, and the next callback picks up where the last one stopped.
    function test_bigSweepPausesAndReactiveContinuesIt() public {
        uint256 max = guard.MAX_ACCOUNTS();
        for (uint256 i; i < max; ++i) {
            address who = address(uint160(0x2000 + i));
            _openEoa(who, nvda, 10e8);
            _openEoa(who, tsla, 10e8);
            usd.mint(who, 10_000e6);
            vm.startPrank(who);
            usd.approve(address(guard), type(uint256).max);
            guard.protect(address(market), 1.25e18, 1.40e18, 10_000e6);
            vm.stopPrank();
        }
        _printAndReact(address(tsla), 400e8);
        _printAndReact(address(tsla), 300e8);

        uint256 forwarded = rx.CALLBACK_GAS_LIMIT() - 130_000;
        uint256 idx = sys.callbackCount() - 1;
        uint256 callbacks;
        while (true) {
            (Vm.Log[] memory logs, uint256 used) = _deliverMeasured(idx, forwarded);
            assertLt(used, forwarded, "every callback fits");
            ++callbacks;
            emit log_named_uint("callback gas", used);
            uint256 before = sys.callbackCount();
            _reactToGuardLogs(logs);
            if (sys.callbackCount() == before) break;
            idx = sys.callbackCount() - 1;
            assertLt(callbacks, 5);
        }
        assertGt(callbacks, 1, "needed a continuation");
        assertEq(rx.continuations(), callbacks - 1);
        assertEq(guard.rescues(), max, "every account rescued");
        for (uint256 i; i < max; ++i) {
            assertGe(guard.pessimisticHealthOf(address(market), address(uint160(0x2000 + i))), 1.40e18);
        }
        (address cursorToken,,) = guard.cursorOf(address(market));
        assertEq(cursorToken, address(0), "cursor cleared once the sweep finished");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Publishes a print through the lab and hands the market's Observed log to the reactive contract the way
    ///      Reactive Network would. Returns how many callbacks that requested.
    function _printAndReact(address token, int256 answer) internal returns (uint256) {
        uint256 before = sys.callbackCount();
        vm.recordLogs();
        lab.print(token, answer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(market) && logs[i].topics[0] == OBSERVED) {
                (uint80 roundId, int256 a) = abi.decode(logs[i].data, (uint80, int256));
                vm.prank(SYSTEM);
                rx.react(_observedRecord(address(uint160(uint256(logs[i].topics[1]))), roundId, a));
            }
        }
        return sys.callbackCount() - before;
    }

    function _observedRecord(address token, uint256 roundId, int256 answer)
        internal
        view
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = block.chainid;
        r.contractAddress = address(market);
        r.topic0 = uint256(OBSERVED);
        r.topic1 = uint256(uint160(token));
        r.data = abi.encode(uint80(roundId), answer);
        r.blockNumber = block.number;
        r.opCode = 2;
    }

    /// @dev Delivers a requested callback the way the callback proxy would: from the proxy, with the first argument
    ///      overwritten by the address of the reactive contract that asked for it.
    function _deliver(uint256 i) internal {
        _deliverMeasured(i, sys.callbackAt(i).gasLimit);
    }

    function _deliverMeasured(uint256 i, uint256 gas) internal returns (Vm.Log[] memory logs, uint256 used) {
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(i);
        assertEq(c.chainId, block.chainid);
        bytes memory payload = c.payload;
        bytes32 sender = bytes32(uint256(uint160(address(rx))));
        assembly {
            mstore(add(payload, 36), sender)
        }
        vm.recordLogs();
        vm.prank(proxy);
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = c.recipient.call{gas: gas}(payload);
        used = before - gasleft();
        assertTrue(ok, string(ret));
        logs = vm.getRecordedLogs();
    }

    /// @dev Hands the guard's SweepPaused logs to the reactive contract, as Reactive Network would.
    function _reactToGuardLogs(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(guard) || uint256(logs[i].topics[0]) != rx.SWEEP_PAUSED_TOPIC_0()) continue;
            IReactive.LogRecord memory r;
            r.chainId = block.chainid;
            r.contractAddress = address(guard);
            r.topic0 = uint256(logs[i].topics[0]);
            r.topic1 = uint256(logs[i].topics[1]);
            r.topic2 = uint256(logs[i].topics[2]);
            r.data = logs[i].data;
            r.blockNumber = block.number;
            r.opCode = logs[i].topics.length;
            vm.prank(SYSTEM);
            rx.react(r);
        }
    }

    function _args(bytes memory payload) internal pure returns (bytes memory args) {
        args = new bytes(payload.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = payload[i + 4];
        }
    }

    function _liquidationOutcome(Vm.Log[] memory logs, address g, address u) internal view returns (bool gl, bool ul) {
        bytes32 sig = keccak256("LiquidationAttempt(uint256,address,bool,uint256,uint256,uint256,uint64)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(lab) || logs[i].topics[0] != sig) continue;
            address account = address(uint160(uint256(logs[i].topics[2])));
            (bool liquidated,,,,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint64));
            if (account == g) gl = liquidated;
            if (account == u) ul = liquidated;
        }
    }

    function _sweepSummary(Vm.Log[] memory logs) internal view returns (uint256 checked, uint256 rescued, uint256 failures) {
        bytes32 handled =
            keccak256("PrintHandled(address,address,uint80,int256,int256,uint256,uint256,uint256,uint64,uint256,uint256)");
        bytes32 failed = keccak256("GuardFailed(address,address,uint80,uint256,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(guard)) continue;
            if (logs[i].topics[0] == handled) {
                (,,,,,,, checked, rescued) = abi.decode(
                    logs[i].data, (uint80, int256, int256, uint256, uint256, uint256, uint64, uint256, uint256)
                );
            } else if (logs[i].topics[0] == failed) {
                ++failures;
            }
        }
    }

    function _openEoa(address who, IB20 token, uint256 units) internal {
        token.mint(who, units);
        vm.startPrank(who);
        token.approve(address(market), units);
        market.depositCollateral(address(token), units);
        market.borrow(market.borrowPowerOf(who) - market.debtOf(who));
        vm.stopPrank();
    }

    function _relay(uint256 feedId, uint80 roundId, int256 answer) internal {
        uint256[] memory ids = new uint256[](1);
        uint80[] memory rounds = new uint80[](1);
        int256[] memory answers = new int256[](1);
        uint64[] memory ts = new uint64[](1);
        ids[0] = feedId;
        rounds[0] = roundId;
        answers[0] = answer;
        ts[0] = uint64(block.timestamp);
        hub.relay(ids, rounds, answers, ts, ts);
    }

    function _stablecoin() internal returns (IB20 token) {
        token = IB20(
            StdPrecompiles.B20_FACTORY.createB20(
                IB20Factory.B20Variant.STABLECOIN,
                keccak256("bell-guard-test-usd"),
                B20FactoryLib.encodeStablecoinCreateParams("Guard Test USD", "gtUSD", address(this), "USD"),
                new bytes[](0)
            )
        );
        token.grantRole(B20Constants.MINT_ROLE, address(this));
    }

    function _stock(string memory t) internal returns (IB20 token) {
        token = IB20(
            StdPrecompiles.B20_FACTORY.createB20(
                IB20Factory.B20Variant.ASSET,
                keccak256(bytes(string.concat("bell-guard-test-", t))),
                B20FactoryLib.encodeAssetCreateParams(t, string.concat("gt", t), address(this), 8),
                new bytes[](0)
            )
        );
        token.grantRole(B20Constants.MINT_ROLE, address(this));
    }
}
