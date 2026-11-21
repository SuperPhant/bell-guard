// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

import {BellMarket} from "bell/BellMarket.sol";
import {MirrorFeedHub} from "bell/testnet/MirrorFeedHub.sol";
import {MirrorOracleRegistry} from "bell/testnet/MirrorOracleRegistry.sol";
import {AggregatorV3Interface} from "bell/interfaces/AggregatorV3Interface.sol";
import {IOracleRegistry} from "bell/interfaces/IOracleRegistry.sol";

import {BellGuard} from "../src/BellGuard.sol";
import {CrashLab} from "../src/sandbox/CrashLab.sol";

interface ICallbackProxy {
    function depositTo(address target) external payable;
}

/// @notice Deploys the Base Sepolia side: BellGuard, plus a sandbox Bell market whose TSLA price CrashLab sets.
///         The sandbox reuses the live Bell market's tUSD and tTSLAc tokens, rates and TSLA risk parameters, and
///         starts at the live TSLA price.
///
///         REACTIVE_ADDRESS is BellGuardReactive's address on Lasna, known before it exists (the operator wallet's
///         first deployment), because the guard stores it immutably.
///
///         forge script script/DeployBase.s.sol --rpc-url base_sepolia --broadcast --slow
contract DeployBase is Script {
    address constant CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address constant LIVE_MARKET = 0x6d9f3290AAEBF3A207D181250548865BA138039C;
    address constant USD = 0xB200000000000000000001C63E9D844496A7bf10;
    address constant TSLA = 0xb200000000000000000000166b22Bb06299e16d5;
    address constant MSTR = 0xB20000000000000000000011e9eDc311b3557A24;
    address constant NVDA = 0xb200000000000000000000A9e9969Eb6B958f57F;
    address constant LIVE_TSLA_FEED = 0x5276c0762F693C376f2f4a1F639CA1b3a6Ae65DA;

    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);
        BellMarket live = BellMarket(LIVE_MARKET);
        int256 tslaPrice = int256(live.priceOf(TSLA).latest);
        (, uint16 ltv, uint16 threshold, uint16 bonus, uint32 maxAge,) = live.configOf(TSLA);

        vm.startBroadcast(pk);

        MirrorFeedHub hub = new MirrorFeedHub(deployer);
        MirrorOracleRegistry registry = new MirrorOracleRegistry(deployer);
        (uint256 feedId, address adapter) = hub.addFeed(LIVE_TSLA_FEED, 8, "TSLA / USD (Bell Guard sandbox)");
        _relay(hub, feedId, 1, tslaPrice);

        BellMarket market =
            new BellMarket(IB20(USD), IOracleRegistry(address(registry)), live.baseRatePerYearRay(), live.slopeRatePerYearRay());
        market.listCollateral(TSLA, AggregatorV3Interface(adapter), ltv, threshold, bonus, maxAge);
        IB20(USD).mint(deployer, 5_000_000e6);
        IB20(USD).approve(address(market), 5_000_000e6);
        market.supply(5_000_000e6);

        BellGuard guard = new BellGuard(IPayable(payable(CALLBACK_PROXY)), reactive);
        guard.allowMarket(address(market), true);
        guard.allowMarket(LIVE_MARKET, true);
        ICallbackProxy(CALLBACK_PROXY).depositTo{value: 0.003 ether}(address(guard));

        CrashLab lab = new CrashLab(market, hub, guard, 1);
        hub.setRelayer(address(lab));
        lab.addStock(TSLA, feedId);
        IB20(USD).grantRole(B20Constants.MINT_ROLE, address(lab));
        IB20(TSLA).grantRole(B20Constants.MINT_ROLE, address(lab));
        IB20(MSTR).grantRole(B20Constants.MINT_ROLE, address(lab));
        IB20(NVDA).grantRole(B20Constants.MINT_ROLE, address(lab));

        vm.stopBroadcast();

        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "reactive", reactive);
        vm.serializeAddress(o, "callbackProxy", CALLBACK_PROXY);
        vm.serializeAddress(o, "guard", address(guard));
        vm.serializeAddress(o, "liveMarket", LIVE_MARKET);
        vm.serializeAddress(o, "sandboxMarket", address(market));
        vm.serializeAddress(o, "sandboxHub", address(hub));
        vm.serializeAddress(o, "sandboxRegistry", address(registry));
        vm.serializeAddress(o, "sandboxTslaFeed", adapter);
        vm.serializeAddress(o, "crashLab", address(lab));
        vm.serializeAddress(o, "usd", USD);
        vm.serializeAddress(o, "tsla", TSLA);
        vm.serializeAddress(o, "mstr", MSTR);
        vm.serializeAddress(o, "nvda", NVDA);
        vm.serializeInt(o, "sandboxStartPrice", tslaPrice);
        string memory json = vm.serializeUint(o, "startBlock", block.number);
        vm.writeJson(json, "./deployments/84532.json");
        console.log("guard", address(guard));
        console.log("sandbox market", address(market));
        console.log("crash lab", address(lab));
    }

    function _relay(MirrorFeedHub hub, uint256 feedId, uint80 roundId, int256 answer) internal {
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
}
